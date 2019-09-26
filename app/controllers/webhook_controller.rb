require 'line/bot'
require 'net/http'
require 'uri'
require 'json'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化

  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end

  def callback
    body = request.body.read
    GOOGLEAPI_ENDPOINT "https://www.googleapis.com"
    CALILAPI_ENDPOINT "http://api.calil.jp"

    signature = request.env['HTTP_X_LINE_SIGNATURE']
    unless client.validate_signature(body, signature)
      head 470
    end

    events = client.parse_events_from(body)
    events.each { |event|
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          user_query = URI.escape(event.message['text'], /[^-_.!~*'()a-zA-Z\d]/u)
          uri = URI.parse(GOOGLEAPI_ENDPOINT + "/books/v1/volumes?q=" + user_query)
          begin
            response = Net::HTTP::start(url.host, usrl.port, user_ssl: uri.scheme == 'https') do |http|
              http.get(uri.request_uri)
            end
          rescue => e
            text = "書籍情報の取得に失敗しましたGoogleが悪いよー"
          end
          text = ""
          response_json = JSON.parse(response.body)
          for index in 0..9 do
            text << response_json['items'][index]['volumeInfo']['title'] + "\n"
          end
          message = {
            type: 'text',
            text: text
          }
          client.reply_message(event['replyToken'], message)
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        when Line::Bot::Event::MessageType::Location
        calil_appkey = ENV["CALIL_APPKEY"]
        latitude = event.message['latitude']
        longitude = event.message['longitude']
        uri = URI.parse(CALILAPI_ENDPOINT + "/library?appkey=#{calil_appkey}&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")
          begin
            response = Net::HTTP::start(url.host, usrl.port, user_ssl: uri.scheme == 'https') do |http|
              http.get(uri.request_uri)
            end
          rescue => e
            text = "書籍情報の取得に失敗しましたカーリルが悪いよー"
          end
        text = ""
        response_json = JSON.parse(response.body)
        for value in response_json do
          text << "#{value["short"]}\n"
        end

        message = {
          type: 'text',
          text: text
        }
        client.reply_message(event['replyToken'], message)
        end
      end
    }
    head :ok
  end
end
