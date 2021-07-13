require "http"
require "placeos-models"

module PlaceOS::Api
  module Utils::Responders
    # Write JSON to the response IO
    #
    macro render_json(status = :ok, &block)
      %response = @context.response
      %response.status = {{status}}
      %response.content_type = "application/json"
      JSON.build(%response) {{block}}
      @render_called = true
      return
    end

    # Renders API error messages in a consistent format
    #
    def render_error(status : HTTP::Status, message : String?, **additional)
      message = "API error" if message.nil?
      render status: status, json: additional.merge({message: message})
    end

    # Shortcut to save a record and render a response
    #
    # Accepts an optional block to process the entity before response.
    def save_and_respond(resource)
      result, status = save_and_status(resource)

      if status.ok? && result.is_a?(PlaceOS::Model::ModelBase)
        result = yield result
      end

      render json: result, status: status
    end

    # :ditto:
    def save_and_respond(resource)
      save_and_respond(resource) { resource }
    end

    # Shortcut to save a record and give the correct status
    def save_and_status(resource)
      creation = resource.new_record?
      if resource.save
        {resource, creation ? HTTP::Status::CREATED : HTTP::Status::OK}
      else
        {resource.errors.map(&.to_s), HTTP::Status::UNPROCESSABLE_ENTITY}
      end
    end

    # Merge fields into object
    def with_fields(model, fields) : Hash
      attrs = Hash(String, JSON::Any).from_json(model.to_json)
      attrs.merge(fields)
    end

    # Restrict model attributes
    def restrict_attributes(
      model,
      only : Array(String)? = nil,   # Attributes to keep
      except : Array(String)? = nil, # Attributes to exclude
      fields : Hash? = nil           # Additional fields
    ) : Hash
      # Necessary for fields with converters defined
      attrs = Hash(String, JSON::Any).from_json(model.to_json)
      attrs.select!(only) if only
      attrs.reject!(except) if except

      fields && !fields.empty? ? attrs.merge(fields) : attrs
    end

    private alias DriverError = Driver::Proxy::RemoteDriver::ErrorCode

    # RemoteDriver Execute error responder
    #
    # With respond = `true`, method acts as a logging function
    def handle_execute_error(error : Driver::Proxy::RemoteDriver::Error, respond : Bool = true)
      message = error.error_code.to_s.gsub('_', ' ')
      Log.context.set(
        error: message,
        sys_id: error.system_id,
        module_name: error.module_name,
        index: error.index,
        remote_backtrace: error.remote_backtrace,
      )

      status = case error.error_code
               in DriverError::ModuleNotFound, DriverError::SystemNotFound
                 Log.info { error.message }
                 HTTP::Status::NOT_FOUND
               in DriverError::ParseError, DriverError::BadRequest, DriverError::UnknownCommand
                 Log.error { error.message }
                 HTTP::Status::BAD_REQUEST
               in DriverError::RequestFailed, DriverError::UnexpectedFailure
                 Log.info { error.message }
                 HTTP::Status::INTERNAL_SERVER_ERROR
               in DriverError::AccessDenied
                 Log.info { error.message }
                 HTTP::Status::UNAUTHORIZED
               end

      render(status: status, json: {
        error:       message,
        sys_id:      error.system_id,
        module_name: error.module_name,
        index:       error.index,
        message:     error.message,
        backtrace:   error.remote_backtrace,
      }) if respond
    end
  end
end
