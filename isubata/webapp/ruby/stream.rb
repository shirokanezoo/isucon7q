require 'redis'
require 'msgpack'

Redis.new.subscribe('isubata:stream:message') do |on|
  on.subscribe do |ch, subs|
    puts "AwesomeFetch subscribed to #{ch.inspect} (#{subs} subscriptions)"
  end

  on.message do |ch, message|
    payload = message.empty? ? nil : MessagePack.unpack(message)
    p payload
  end

end
