class PlaceOS::Driver; end

# Application dependencies
require "action-controller"

# Application code
require "./logging"
require "./api"

# Server required after application controllers
require "action-controller/server"

module PlaceOS::Api
  # Configure Service discovery
  HoundDog.configure do |settings|
    settings.etcd_host = Api::ETCD_HOST
    settings.etcd_port = Api::ETCD_PORT
  end

  filters = ["bearer_token", "secret", "password"]

  # Add handlers that should run before your application
  ActionController::Server.before(
    ActionController::ErrorHandler.new(Api.production?, ["X-Request-ID"]),
    Raven::ActionController::ErrorHandler.new,
    ActionController::LogHandler.new(filters, ms: true)
  )
end
