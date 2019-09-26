require 'line/bot'
require 'net/http'
require 'uri'
require 'json'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化
  @@user_data = []

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
      userId = event['source']['userId']
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          user_query = URI.escape(event.message['text'], /[^-_.!~*'()a-zA-Z\d]/u)
          uri = URI.parse(GOOGLEAPI_ENDPOINT + "/books/v1/volumes?q=" + user_query)
          text = ""
          response_json = ""
          books_data = []
          data_acquisition = 0
          startIndex = 0
          loop do
            response_json = ""
            begin
              response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
                http.get(uri.request_uri)
              end
              response_json = JSON.parse(response.body)
            rescue => e
              text << "Googlegaが悪いよー"
            end
            response = JSON.parse(Net::HTTP.get(URI.parse(endpoint + "/books/v1/volumes?q=" + user_query_escape + "&startIndex=" + startIndex)))
            startIndex += 1
            if response_json['items'] then
              10.times do |index|
                # ISBNが存在しなければスキップ
                type = response.dig('items', index, 'volumeInfo', 'industryIdentifiers', 'type')
                if type then
                  books_data[index][0] << response.dig('items', index, 'volumeInfo', 'industryIdentifiers', type)
                  books_data[index][1] = response['items'][index]['volumeInfo']['title']
                  books_data[index][2] = response['items'][index]['volumeInfo']['author']
                  data_acquisition += 1
                  break if data_acquisition == 10
                end
              end
            else
              # itemsが存在しない場合break、書籍検索結果自体がないor ISBNを持つ書籍が10件に満たない場合となる
              break
            end
          end
          # 書籍のデータが何件あるかで条件を分岐したい(仮)
          if @@user_data[userId] then
            if @@user_data[userId][:location] then
              # Locationがすでに設定されている
              endpoint = "http://api.calil.jp"
              latitude = @@user_data[userId][:location][:latitude]
              longitude = @@user_data[userId][:location][:longitude]
              library_data = []
              response = JSON.parse(Net::HTTP.get(URI.parse(endpoint + "/library?appkey=#{calil_appkey}&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")))
              response.each_with_index do |value, index|
                library_data[index][0] = value["systemid"]
                library_data[index][1] = value["short"]
              end
              response = JSON.parse(Net::HTTP.get(URI.parse(endpoint + "/check?appkey=#{calil_appkey}&systemid=#{library_data.map{|row| row[0]}.join(',')}&isbn=#{books_data.map{|row| row[0]}.join('')}&format=json&callback=no")))
              # 図書館ごとの応答を吸収するためにcalilAPI側にpollingが実装されているその対応を書く
              while response["continue"] == 1
                # pollingが始まるとjsonp形式でのみ返答となるので整形してからデータを扱う, 配列内部にJSONが格納されていることに注意が必要
                # polling中に適宜情報をクライアントに提示する機能は実装しない
                response = JSON.parse(Net::HTTP.get(URI.parse(endpoint + "/check?appkey=#{calil_appkey}&session#{response["session"]}&format=json")))[/\[.*\]/]
              end
              text = ""
              books_data.length do |book_index|
                text << "title: #{books_data[book_index][1]}\n"
                library_data.length do |library_index|
                  text << "  #{library_data[library_index][1]}: #{response['books'][books_data[book_index][0]]['libkey'].to_a}\n"
                end
              end
            else
              @@user_data[userId][:user_query] = user_query
              text << "位置情報を入力してね\n"
            end
            message = {
              type: 'text',
              text: text
            }
            client.reply_message(event['replyToken'], message)
          end
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        when Line::Bot::Event::MessageType::Location
          calil_appkey = ENV["CALIL_APPKEY"]
          latitude = event.message['latitude']
          longitude = event.message['longitude']
          uri = URI.parse(CALILAPI_ENDPOINT + "/library?appkey=#{calil_appkey}&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")
          text = ""
          response_json = ""
          begin
            response = Net::HTTP.start(uri.host, uri.port) do |http|
              http.get(uri.request_uri)
            end
            response_json = JSON.parse(response.body)
          rescue => e
            p e
          end
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
private
CALILAPI_ENDPOINT = "http://api.calil.jp"
GOOGLEAPI_ENDPOINT = "https://www.googleapis.com"
end

