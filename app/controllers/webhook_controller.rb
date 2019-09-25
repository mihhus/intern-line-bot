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
					response = JSON.parse(Net::HTTP.get(URI.parse("https://www.googleapis.com/books/v1/volumes?q=" + URI.escape(event.message['text'], /[^-_.!~*'()a-zA-Z\d]/u))))
					text = ""
					for index in 0..9 do
						text += {response['items'][index]['volumeInfo']['title'] + "\n"
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
					latitude = event.message['latitude']
					longitude = event.message['longitude']

					# process
					response = JSON.parse(Net::HTTP.get(URI.parse("http://api.calil.jp/library?appkey=b8c0e0e67846679920a4eae16a42cc07&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")))

					text = ""
					for value in response do
						text += "#{value["short"]}\n"
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
