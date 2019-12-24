require 'line/bot'
require 'net/http'
require 'uri'
require 'json'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化
  @@user_data = {} # 現時点では大規模なサービスとして提供するわけでは無いので簡潔に書くためにインメモリで保存する. きちんと実装する時はDB作ってO/Rマッパを書くこと

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
          text = ""
          user_query = URI.escape(event.message['text'], /[^-_.!~*'()a-zA-Z\d]/u)
          books_data = []
          library_data = []
          data_acquisition = 0
          startIndex = 0
          @response_json = 0
          # 書誌情報にISBNを持つ本の情報を10冊集めたらbreakする
          loop do
            uri = URI.parse(GOOGLEAPI_ENDPOINT + "/books/v1/volumes?q=" + user_query + "&maxResults=10&startIndex=" + startIndex.to_s)
            begin
              # モジュール化
              response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
                http.get(uri.request_uri)
              end
              @response_json = JSON.parse(response.body)
            rescue
              text << "Googleが悪いよ~ ";
            end
            break unless @response_json.has_key?('items')  # リクエストの返事に書誌データがなければ検索を打ち切る
            @response_json['items'].each do |item|
              # モジュール化
              # ISBNが存在しなければスキップ
              industrys = item.dig('volumeInfo', 'industryIdentifiers')
              next if industrys == nil
              industry = industrys if industrys.kind_of?(Hash)
              industry = industrys[0] if industrys.kind_of?(Array)
              type = industry.dig('type')
              if type == "ISBN_10" || type == "ISBN_13" then
                  books_data.push([industry['identifier'], item['volumeInfo']['title']])
                  data_acquisition += 1
              end
            end
            break if data_acquisition > 9
            startIndex += 1
          end

          if @@user_data.has_key?(userId) then
            if @@user_data[userId].has_key?(:location) then
              calil_appkey = ENV["CALIL_APPKEY"]
              # Locationがすでに設定されている
              latitude = @@user_data[userId][:location][:latitude]
              longitude = @@user_data[userId][:location][:longitude]
              uri = URI.parse(CALILAPI_ENDPOINT + "/library?appkey=#{calil_appkey}&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")
              begin
                # モジュール化
                response = Net::HTTP.start(uri.host, uri.port) do |http|
                  http.get(uri.request_uri)
                end
                @response_json = JSON.parse(response.body)
              rescue
                text << "カーリルが悪いよー\n"
              end
              @response_json.each_with_index do |value, index|
                library_data.push([value["systemid"],value["short"]])
              end
              # uri = URI.parse(CALILAPI_ENDPOINT + "/check?appkey=#{calil_appkey}&isbn=#{books_data.map{|row| row[0]}.join(',')}&systemid=#{library_data.map{|row| row[0]}.join(',')}&format=json&callback=no")
              no = "no"
              uri = URI.parse(CALILAPI_ENDPOINT + "/check?appkey=#{calil_appkey}&isbn=#{books_data.map{|row| row[0]}.join(',')}&systemid=#{library_data.map{|row| row[0]}.join(',')}&format=json&callback=#{no}")
              begin
                response = Net::HTTP.start(uri.host, uri.port) do |http|
                  http.get(uri.request_uri)
                end
                @response_json = JSON.parse(response.body)
              rescue
                text << "カーリルが悪いよー\n"
              end
              # 図書館ごとの応答を吸収するためにcalilAPI側にpollingが実装されているその対応を書く
              while @response_json["continue"] == 1 do
                # pollingが始まるとjsonp形式でのみ返答となるので整形してからデータを扱う, 配列内部にJSONが格納されていることに注意が必要
                uri = URI.parse(CALILAPI_ENDPOINT + "/check?appkey=#{calil_appkey}&session#{@response_json["session"]}&format=json")
                begin
                  response = Net::HTTP.start(uri.host, uri.port) do |http|
                    http.get(uri.request_uri)
                  end
                  @response_json = JSON.parse(response.body[/\[.*\]/])  # 全体の外に余分なカッコがついているので除去する
                rescue
                  text << "カーリルが悪いよー\n"
                end
              end
              books_data.each_with_index do |book_item, book_index|
                # モジュール化
              message = {
                type: 'text',
                text: books_item[0]
              }
              client.reply_message(event['replyToken'], message)
                break if book_index == 2  #情報が1テキストに入り切らないので暫定的に書籍情報を2個だけにする
                library_data.each_with_index do |library_item, library_index|
                  # text << "  #{library_item[1]}: #{@response_json.dig('books', book_item[0], library_item[0])}\n"
                # library_item[1]内部に欲しいデータが格納されているが、JSONとして(各図書館ごとにバラバラに)返却されるので手直しが必要
                end
              end
            end
          end
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        when Line::Bot::Event::MessageType::Location
          calil_appkey = ENV["CALIL_APPKEY"]
          # locationの取得方法&格納をモジュール化
          latitude = event.message['latitude']
          longitude = event.message['longitude']
          @@user_data[userId] = {:location => {:latitude => latitude, :longitude => longitude}}
          uri = URI.parse(CALILAPI_ENDPOINT + "/library?appkey=#{calil_appkey}&geocode=#{longitude},#{latitude}&limit=10&format=json&callback= ")
          begin
            # モジュール化
            response = Net::HTTP.start(uri.host, uri.port) do |http|
              http.get(uri.request_uri)
            end
            response_json = JSON.parse(response.body)
          rescue
            text << "カーリルが悪いよ \n"
          end
          text = ""
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

def getAPIs(uri, usr_ssl = nil)
    begin
       if(use_ssl == "https") then
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
            http.get(uri.request_uri)
          end
       else
         response = Net::HTTP.start(uri.host, uri.port) do |http|
           http.get(uri.request_uri)
         end
       end
       return JSON.parse(response.body)
    rescue => e
      return e
    end
end

def getISBNs(uri)
  books = []
  data_acquisition = 0
  startIndex += 1
  loop do
    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.get(uri.request_uri)
      end
      @response_json = JSON.parse(response.body)
    rescue
      text << "Googleが悪いよ~ ";
    end
    break unless @response_json.has_key?('items')  # リクエストの返事に書誌データがなければ検索を打ち切る
    @response_json['items'].each do |item|
      # ISBNが存在しなければスキップ
      industrys = item.dig('volumeInfo', 'industryIdentifires')
      if industrys.kind_of?(Hash) then
          industry = industrys
      end
      if industrys.kind_of?(Array) then
          industry = industrys[0]
      end
      industry = industrys if industrys.kind_of?(Hash)
      industry = industrys[0] if industrys.kind_of?(Array)

      type = industry.dig('type')
      if type == "ISBN_10" || type == "ISBN_13" then
          books_data.push(industry.dig('identifier'), item['volumeInfo']['title'])
          data_acquisition += 1
      end
    end
    break if data_acquisition > 10
    startIndex += 1
  end

  return books
end

def getNearbyLibs(uri)

    return librarys
end

def polling(uri, session_num)

    return response_json
end
