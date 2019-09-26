require 'net/http'
require 'uri'
require 'json'
GOOGLEAPI_ENDPOINT = "https://www.googleapis.com"
user_query = URI.escape("人間失格", /[^-_.!~*'()a-zA-Z\d]/u)
uri = URI.parse(GOOGLEAPI_ENDPOINT + "/books/v1/volumes?q=" + user_query)
begin
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
  http.get(uri.request_uri)
  end
  # response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
rescue => e
  p e
end
response_json = JSON.parse(response.body)

print response_json['items'][0]['volumeInfo']['title']

__END__
case response
when Net::HTTPSuccess
  print response.body
when Net::HTTPRedirection
  location = response['location']
else
  puts [uri.to_s, response.value].join(" : ")
  nil
end
