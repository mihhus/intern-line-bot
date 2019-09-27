require 'line/bot'
require 'net/http'
require 'uri'
require 'json'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化
  @@user_data = {"test" => "tester"}

  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end

  def callback
    body = request.body.read
    text = ""

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
          text = ""
          user_query = URI.escape(event.message['text'], /[^-_.!~*'()a-zA-Z\d]/u)
          books_data = []
          library_data = []
          data_acquisition = 0
          startIndex = 0
          # 書誌情報にISBNを持つ本の情報を10冊集めたらbreakする
          loop do
            uri = URI.parse(GOOGLEAPI_ENDPOINT + "/books/v1/volumes?q=" + user_query + "&maxResults=10&startIndex=" + startIndex.to_s)
            begin
              response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
                http.get(uri.request_uri)
              end
              @response_json = JSON.parse(response.body)
            rescue => e
              text << "Googlegaが悪いよー"
            end
            
            break unless @response_json.has_key?('items')
            @response_json['items'].each do |item|
              # ISBNが存在しなければスキップ
              if industry = item.dig('volumeInfo', 'industryIdentifiers') then
                if industry.kind_of?(Hash) then
                  type = industry.dig('type')
                  if type == "ISBN_10" || type == "ISBN_13" then
                    books_data.push([industry.dig('identifier'), item['volumeInfo']['title'], item['volumeInfo']['author']])
                    data_acquisition += 1
                    break if data_acquisition == 10
                  end
                elsif industry.kind_of?(Array) then
                  type = industry[0].dig('type')
                  if type == "ISBN_10" || type == "ISBN_13" then
                    books_data.push([industry[0].dig('identifier'), item['volumeInfo']['title'], item['volumeInfo']['author']])
                    data_acquisition += 1
                  end
                end
              end
            end
            break if data_acquisition > 10
            startIndex += 1
          end

          # 書籍のデータが何件あるかで条件を分岐したい(仮)
          if @@user_data.has_key?(userId) then
            text << "ugoite"
            if @@user_data[userId].has_key?(:location) then
              calil_appkey = ENV["CALIL_APPKEY"]
              # Locationがすでに設定されている
              latitude = @@user_data[userId][:location][:latitude]
              longitude = @@user_data[userId][:location][:longitude]
              uri = URI.parse(CALILAPI_ENDPOINT + "/library?appkey=#{calil_appkey}&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")
              begin
                response = Net::HTTP.start(uri.host, uri.port) do |http|
                  http.get(uri.request_uri)
                end
                @response_json = JSON.parse(response.body)
              rescue => e
                text << "カーリルが悪いよー\n"
              end
              @response_json.each_with_index do |value, index|
                library_data.push([value["systemid"],value["short"]])
              end
              uri = URI.parse(CALILAPI_ENDPOINT + "/check?appkey=#{calil_appkey}&systemid=#{library_data.map{|row| row[0]}.join(',')}&isbn=#{books_data.map{|row| row[0]}.join('')}&format=json&callback=no")
              begin
                response = Net::HTTP.start(uri.host, uri.port) do |http|
                  http.get(uri.request_uri)
                end
                @response_json = JSON.parse(response.body)
              rescue => e
                text << "カーリルが悪いよー\n"
              end
              # 図書館ごとの応答を吸収するためにcalilAPI側にpollingが実装されているその対応を書く
              while @response_json["continue"] == 1 do
                # pollingが始まるとjsonp形式でのみ返答となるので整形してからデータを扱う, 配列内部にJSONが格納されていることに注意が必要
                uri = URI.parse(CALILAPI_ENDPOINT + "/check?appkey=#{calil_appkey}&session#{response["session"]}&format=json")
                begin
                  response = Net::HTTP.start(uri.host, uri.port) do |http|
                    http.get(uri.request_uri)
                  end
                  @response_json = JSON.parse(response.body[/\[.*\]/])
                rescue => e
                  text << "カーリルが悪いよー\n"
                end
              end
              text << "syuturyokunotoko\n"
              books_data.each_with_index do |book_item, book_index|
                text << "title\n"
                # text << "title: #{books_data[book_index][1]}\n"
                # library_data.each_with_index do |library_item, library_index|
                  # text << "  author\n"
                  # text << "  #{library_data[library_index][1]}: #{@response_json['books'][books_data[book_index][0]]['libkey'].to_a}\n"
              end
            else
              @@user_data[userId] = {:user_query => user_query}
              text << "位置情報を入力してね"
            end
          end
          # text << @response_json['items'][0]['volumeInfo']['title'].to_s

          text << @@user_data.to_s
          text << "test"
          text << books_data.length.to_s
          text << library_data.lenght.to_s
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
          @@user_data[userId] = {:location => {:latitude => latitude, :longitude => longitude}}
          uri = URI.parse(CALILAPI_ENDPOINT + "/library?appkey=#{calil_appkey}&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")
          begin
            response = Net::HTTP.start(uri.host, uri.port) do |http|
              http.get(uri.request_uri)
            end
            response_json = JSON.parse(response.body)
          rescue => e
            p e
          end
          text = ""
          for value in response_json do
            text << "#{value["short"]}\n"
          end
          text << @@user_data.to_s
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

