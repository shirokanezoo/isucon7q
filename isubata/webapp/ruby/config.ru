require './app'

unless ENV['ISUCON7_DISABLE_LOGS'] == '1'
  require 'logger'
  require 'rack/ltsv_logger'
  class VanillaLogger < ::Logger
    def write(msg)
      @logdev.write msg
    end
  end
  use Rack::LtsvLogger, VanillaLogger.new('/tmp/isu-rack.log')
end

run App
