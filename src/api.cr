require "action-controller/logger"
require "log_helper"
require "secrets-env"

require "./constants"
require "./api/application"
require "./api/*"

module PlaceOS::Api
  Log = ::Log.for(self)

  LOG_STDOUT    = ActionController.default_backend
  LOGSTASH_HOST = ENV["LOGSTASH_HOST"]?
  LOGSTASH_PORT = ENV["LOGSTASH_PORT"]?

  def self.log_backend
    if !(logstash_host = LOGSTASH_HOST.presence).nil?
      logstash_port = LOGSTASH_PORT.try(&.to_i?) || abort("LOGSTASH_PORT is either malformed or not present in environment")

      # Logstash UDP Input
      logstash = UDPSocket.new
      logstash.connect logstash_host, logstash_port
      logstash.sync = false

      # debug at the broadcast backend level, however this will be filtered
      # by the bindings
      backend = ::Log::BroadcastBackend.new
      backend.append(LOG_STDOUT, :trace)
      backend.append(ActionController.default_backend(
        io: logstash,
        formatter: ActionController.json_formatter
      ), :trace)
      backend
    else
      LOG_STDOUT
    end
  end

  class_getter? production : Bool = PROD
end
