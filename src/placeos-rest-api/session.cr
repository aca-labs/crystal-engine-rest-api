# FIXME: Hack to allow resolution of PlaceOS::Driver class/module
class PlaceOS::Driver; end

require "hound-dog"
require "log"
require "placeos-driver/proxy/remote_driver"
require "tasker"

require "./error"
require "./utilities/params"

module PlaceOS
  class Api::Session
    Log = ::Log.for(self)

    # Stores sessions until their websocket closes
    class Manager
      private getter sessions : Array(Session) { [] of Session }
      private getter session_lock = Mutex.new
      private getter discovery : HoundDog::Discovery

      def initialize(@discovery : HoundDog::Discovery)
      end

      # Creates the session and handles the cleanup
      #
      def create_session(ws, request_id, user)
        session = Session.new(
          ws: ws,
          request_id: request_id,
          user: user,
          discovery: discovery,
        )

        session_lock.synchronize { sessions << session }
        ws.on_close do |_|
          Log.trace { {frame: "CLOSE"} }
          session.cleanup
          sessions.delete(session)
          session_lock.synchronize { sessions.delete(session) }
        end
      end
    end

    # Class level subscriptions to modules
    class_getter subscriptions : Driver::Proxy::Subscriptions = Driver::Proxy::Subscriptions.new

    # Local subscriptions
    private getter bindings = {} of String => Driver::Subscriptions::Subscription

    # Background task to clear module metadata caches
    @cache_cleaner : Tasker::Task?

    # NOTE: Might need a rw-lock/concurrent-map due to cache cleaning fiber
    private getter metadata_cache = {} of String => Driver::DriverModel::Metadata
    private getter module_id_cache = {} of String => String

    getter ws : HTTP::WebSocket

    def initialize(
      @ws : HTTP::WebSocket,
      @request_id : String,
      @user : Model::UserJWT,
      @discovery : HoundDog::Discovery = HoundDog::Discovery.new(CORE_NAMESPACE),
      @cache_timeout : Int32? = 60 * 5
    )
      # Register event handlers
      ws.on_message do |message|
        Log.trace { {frame: "TEXT", text: message} }
        on_message(message)
      end

      ws.on_ping do
        Log.trace { {frame: "PING"} }
        ws.pong
      end

      @security_level = if @user.is_admin?
                          Driver::Proxy::RemoteDriver::Clearance::Admin
                        elsif @user.is_support?
                          Driver::Proxy::RemoteDriver::Clearance::Support
                        else
                          Driver::Proxy::RemoteDriver::Clearance::User
                        end

      # Begin clearing cache
      spawn(name: "cache_cleaner", same_thread: true) { cache_plumbing }
    end

    # Websocket API
    ##############################################################################
    private abstract struct Base
      include JSON::Serializable
    end

    # A websocket API request
    struct Request < Base
      include JSON::Serializable::Strict

      # Commands available over websocket API
      enum Command
        Exec
        Bind
        Unbind
        Debug
        Ignore
      end

      def initialize(
        @id,
        @sys_id,
        @module_name,
        @command,
        @name,
        @index = 1,
        @args = nil
      )
      end

      getter id : Int64

      # Module location metadata
      @[JSON::Field(key: "sys")]
      getter sys_id : String

      @[JSON::Field(key: "mod")]
      getter module_name : String

      getter index : Int32 = 1

      # Command
      @[JSON::Field(key: "cmd")]
      getter command : Command

      # Function name
      getter name : String

      # Function arguments
      @[JSON::Field(emit_null: true)]
      getter args : Array(JSON::Any)?
    end

    alias ErrorCode = Driver::Proxy::RemoteDriver::ErrorCode

    # Websocket API Response
    struct Response < Base
      # Response type
      enum Type
        Success
        Notify
        Error
        Debug
      end

      getter id : Int64
      getter type : Type

      @[JSON::Field(converter: Enum::ValueConverter(PlaceOS::Api::Session::ErrorCode))]
      getter error_code : ErrorCode?

      @[JSON::Field(key: "msg")]
      getter message : String?

      getter value : String?
      getter meta : Metadata?

      @[JSON::Field(key: "mod")]
      getter module_id : String?

      getter level : ::Log::Severity?

      alias Metadata = NamedTuple(
        sys: String,
        mod: String,
        index: Int32,
        name: String,
      )

      def initialize(
        @id,
        @type,
        @error_code = nil,
        @message = nil,
        @value = nil,
        @module_id = nil,
        @level = nil,
        @meta = nil
      )
      end

      class_getter placeholder = %("%{}")

      # Avoids parsing and serialising when payload is already in JSON format
      #
      def self.substitute_value(response : Response, value : String)
        # Cannot use a property as that reallocates the struct
        response.to_json.sub(placeholder, value)
      end
    end

    # Grab core url for the module and dial an exec request
    #
    def exec(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String,
      args : Array(JSON::Any)
    )
      Log.debug { {
        message:       "exec",
        ws_request_id: request_id,
        sys_id:        sys_id,
        module_name:   module_name,
        index:         index,
        name:          name,
        args:          args.to_json,
      } }

      driver = Driver::Proxy::RemoteDriver.new(
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        discovery: @discovery
      )

      response = driver.exec(@security_level, name, args, request_id: @request_id)

      respond(Response.new(
        id: request_id,
        type: Response::Type::Success,
        meta: {
          sys:   sys_id,
          mod:   module_name,
          index: index,
          name:  name,
        },
        value: Response.placeholder,
      ), response)
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message))
    rescue e
      Log.error(exception: e) { {
        message:     "failed to execute request",
        sys_id:      sys_id,
        module_name: module_name,
        index:       index,
        name:        name,
        error:       e.message,
      } }
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to execute request"))
    end

    # Bind a websocket to a module subscription
    #
    def bind(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      Log.debug { {
        message:       "bind",
        ws_request_id: request_id,
        sys_id:        sys_id,
        module_name:   module_name,
        index:         index,
        name:          name,
      } }
      begin
        # Check if module previously bound
        unless has_binding?(sys_id, module_name, index, name)
          return unless create_binding(request_id, sys_id, module_name, index, name)
        end
      rescue error
        Log.warn(exception: error) { {message: "websocket binding could not find system", sys_id: sys_id, module_name: module_name, index: index, name: name} }
        respond(error_response(request_id, ErrorCode::ModuleNotFound, "could not find module: sys=#{sys_id} mod=#{module_name}"))
        return
      end

      # Notify success
      # TODO: Ensure delivery of success before messages
      #       - keep a flag in @bindings hash, set flag once success sent and send message on channel
      #       - notify update gets subscription, checks binding hash for flag, otherwise wait on channel
      # Could use a promise
      response = Response.new(
        id: request_id,
        type: Response::Type::Success,
        meta: {
          sys:   sys_id,
          mod:   module_name,
          index: index,
          name:  name,
        },
      )
      respond(response)
    rescue e
      Log.error(exception: e) { {
        message:       "failed to bind",
        ws_request_id: request_id,
        sys_id:        sys_id,
        module_name:   module_name,
        index:         index,
        name:          name,
        error:         e.message,
      } }
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to bind"))
    end

    # Unbind a websocket from a module subscription
    #
    def unbind(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      Log.debug { {
        message:       "unbind",
        ws_request_id: request_id,
        sys_id:        sys_id,
        module_name:   module_name,
        index:         index,
        name:          name,
      } }

      subscription = delete_binding(sys_id, module_name, index, name)
      self.class.subscriptions.unsubscribe(subscription) if subscription

      respond(Response.new(id: request_id, type: Response::Type::Success))
    rescue e : Driver::Proxy::RemoteDriver::Error
      respond(error_response(request_id, e.error_code, e.message))
    rescue e
      Log.error(exception: e) { {
        message:       "failed to unbind",
        ws_request_id: request_id,
        sys_id:        sys_id,
        module_name:   module_name,
        index:         index,
        name:          name,
        error:         e.message,
      } }
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to unbind"))
    end

    private getter debug_sessions = {} of {String, String, Int32} => HTTP::WebSocket

    # Attach websocket to debug output of a module
    #
    def debug(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      # NOTE: In the interest of saving a redis lookup, the frontend passes
      #       the module_id, rather than name.
      existing_socket = debug_sessions[{sys_id, module_name, index}]?

      if !existing_socket || existing_socket.closed?
        driver = Driver::Proxy::RemoteDriver.new(
          module_id: module_name,
          sys_id: sys_id,
          module_name: module_name,
          discovery: @discovery
        )

        ws = driver.debug
        ws.on_message do |message|
          begin
            level_value, message = Tuple(Int32, String).from_json(message)
            level = ::Log::Severity.from_value(level_value)

            respond(
              Response.new(
                id: request_id,
                module_id: module_name,
                type: Response::Type::Debug,
                level: level,
                message: message,
                meta: {
                  sys:   sys_id,
                  mod:   module_name,
                  index: index,
                  name:  name,
                },
              ))
          rescue e
            Log.warn(exception: e) { {
              message:     "failed to forward debug message",
              sys_id:      sys_id,
              module_name: module_name,
              index:       index,
            } }
          end
        end

        spawn(same_thread: true) { ws.run }
        debug_sessions[{sys_id, module_name, index}] = ws
      else
        Log.trace { {
          message:     "reusing existing debug socket",
          sys_id:      sys_id,
          module_name: module_name,
          index:       index,
        } }
      end

      respond(Response.new(id: request_id, type: Response::Type::Success))
    rescue e
      Log.error(exception: e) { {
        message:       "failed to attach debugger",
        ws_request_id: request_id,
        sys_id:        sys_id,
        module_name:   module_name,
        index:         index,
        name:          name,
      } }
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to attach debugger"))
    end

    # Detach websocket from module debug output
    #
    def ignore(
      request_id : Int64,
      sys_id : String,
      module_name : String,
      index : Int32,
      name : String
    )
      socket = debug_sessions.delete({sys_id, module_name, index})
      # Close the socket if it was present
      socket.try(&.close)
      respond(Response.new(id: request_id, type: Response::Type::Success))
    rescue e
      Log.error(exception: e) { {
        message:       "failed to detach debugger",
        ws_request_id: request_id,
        sys_id:        sys_id,
        module_name:   module_name,
        index:         index,
        name:          name,
      } }
      respond(error_response(request_id, ErrorCode::UnexpectedFailure, "failed to detach debugger"))
    end

    ##############################################################################

    # Looks up the metadata.
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    #
    def metadata?(sys_id, module_name, index) : Driver::DriverModel::Metadata?
      key = Session.cache_key(sys_id, module_name, index)
      # Try for value in the cache
      cached = metadata_cache[key]?
      return cached if cached

      # Look up value, refresh cache if value found
      if (module_id = module_id?(sys_id, module_name, index))
        Driver::Proxy::System.driver_metadata?(module_id).tap do |metadata|
          metadata_cache[key] = metadata if metadata
        end
      end
    end

    # Looks up the module_id
    # - checks for fresh value in cache
    # - refreshes cache with new value if present
    #
    def module_id?(sys_id, module_name, index) : String?
      key = Session.cache_key(sys_id, module_name, index)
      # Try for value in the cache
      cached = module_id_cache[key]?
      return cached if cached

      # Look up value, refresh cache if value found
      Driver::Proxy::System.module_id?(sys_id, module_name, index).tap do |id|
        module_id_cache[key] = id if id
      end
    end

    # Check for existing binding to a module
    #
    def has_binding?(sys_id, module_name, index, name)
      bindings.has_key? Session.binding_key(sys_id, module_name, index, name)
    end

    # Create a binding to a module on the Session
    #
    def create_binding(request_id, sys_id, module_name, index, name) : Bool
      key = Session.binding_key(sys_id, module_name, index, name)

      if module_name.starts_with?("_") && !@user.is_support?
        Log.warn { {message: "websocket binding attempted to access privileged module", sys_id: sys_id, module_name: module_name, index: index, name: name} }
        respond error_response(request_id, ErrorCode::AccessDenied, "attempted to access protected module")
        return false
      end

      if module_name == "_TRIGGER_"
        # Ensure the trigger exists
        trig = Model::TriggerInstance.find(name)
        unless trig.try(&.control_system_id) == sys_id
          Log.warn { {message: "websocket binding attempted to access unknown trigger", sys_id: sys_id, trig_id: name} }
          respond error_response(request_id, ErrorCode::ModuleNotFound, "no trigger #{name} in system #{sys_id}")
          return false
        end

        # Triggers should be subscribed to directly.
        bindings[key] = self.class.subscriptions.subscribe(name, "state") do |_, event|
          notify_update(
            request_id: request_id,
            system_id: sys_id,
            module_name: module_name,
            status: name,
            index: index,
            value: event
          )
        end
      else
        # Subscribe and set local binding
        bindings[key] = self.class.subscriptions.subscribe(sys_id, module_name, index, name) do |_, event|
          notify_update(
            request_id: request_id,
            system_id: sys_id,
            module_name: module_name,
            status: name,
            index: index,
            value: event
          )
        end
      end

      true
    end

    # Create a binding to a module on the Session
    #
    def delete_binding(sys_id, module_name, index, name)
      key = Session.binding_key(sys_id, module_name, index, name)
      bindings.delete key
    end

    # Event handlers
    ###########################################################################

    # Parse an update from a subscription and pass to listener
    #
    def notify_update(value, request_id, system_id, module_name, index, status)
      response = Response.new(
        id: request_id,
        type: Response::Type::Notify,
        value: value,
        meta: {
          sys:   system_id,
          mod:   module_name,
          index: index,
          name:  status,
        },
      )
      respond(response)
    end

    # Request handler
    #
    protected def on_message(data)
      return ws.send("pong") if data == "ping"

      # Execute the request
      request = parse_request(data)
      __send__(request) if request
    rescue e
      Log.error(exception: e) { {message: "websocket request failed", data: data} }
      response = error_response(request.try(&.id), ErrorCode::RequestFailed, e.message)
      respond(response)
    end

    # Shutdown handler
    #
    def cleanup
      # Stop the cache cleaner
      @cache_cleaner.try &.cancel

      # Unbind all modules
      bindings.clear

      # Ignore (stop debugging) all modules
      debug_sessions.each_value &.close
      debug_sessions.clear
    end

    # Utilities
    ###########################################################################

    # Index into module websocket sessions
    def self.binding_key(sys_id, module_name, index, name)
      "#{sys_id}_#{module_name}_#{index}_#{name}"
    end

    # Index into module_id cache
    def self.cache_key(sys_id, module_name, index)
      "#{sys_id}_#{module_name}_#{index}"
    end

    # Headers for requesting engine core,
    # - forwards request id for tracing
    protected def default_headers
      HTTP::Headers{
        "X-Request-ID" => @request_id,
        "Content-Type" => "application/json",
      }
    end

    # Ensures
    # - required params present
    # - command recognised
    def parse_request(data) : Request?
      Request.from_json(data)
    rescue e
      Log.warn { {message: "failed to parse", data: data} }
      error_response(NamedTuple(id: Int64?).from_json(data)[:id], ErrorCode::BadRequest, "bad request: #{e.message}")
      return
    end

    protected def error_response(
      request_id : Int64?,
      error_code : ErrorCode?,
      message : String?
    )
      Api::Session::Response.new(
        id: request_id || 0_i64,
        type: Api::Session::Response::Type::Error,
        error_code: error_code,
        message: message || "",
      )
    end

    # Empty's metadata cache upon cache_timeout
    #
    protected def cache_plumbing
      if (timeout = @cache_timeout) && timeout > 0
        @cache_cleaner = Tasker.instance.every(timeout.seconds) do
          Log.trace { "cleaning websocket session cache" }
          metadata_cache.clear
          module_id_cache.clear
        end
      end
    end

    protected def respond(response : Response, payload : String? = nil)
      return if ws.closed?

      ws.send(payload ? Response.substitute_value(response, payload) : response.to_json)
    end

    # Delegate request to correct handler
    #
    protected def __send__(request : Request)
      arguments = {
        request_id:  request.id,
        sys_id:      request.sys_id,
        module_name: request.module_name,
        index:       request.index,
        name:        request.name,
      }
      case request.command
      in .bind?   then bind(**arguments)
      in .unbind? then unbind(**arguments)
      in .debug?  then debug(**arguments)
      in .ignore? then ignore(**arguments)
      in .exec?   then exec(**arguments, args: request.args.as(Array(JSON::Any)))
      end
    end
  end
end
