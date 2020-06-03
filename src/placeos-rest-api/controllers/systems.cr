require "hound-dog"

require "placeos-core/client"
require "driver/proxy/system"

require "./application"
require "./settings"
require "../session"

module PlaceOS::Api
  class Systems < Application
    include Utils::CoreHelper

    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    base "/api/engine/v2/systems/"

    id_param :sys_id

    before_action :check_admin, except: [:index, :show, :control, :execute,
                                         :types, :functions, :state, :state_lookup]

    before_action :check_support, only: [:state, :state_lookup, :functions]

    before_action :find_system, only: [:show, :update, :destroy, :remove,
                                       :start, :stop, :execute, :types, :functions]

    before_action :ensure_json, only: [:create, :update, :update_alt, :execute]

    getter control_system : Model::ControlSystem?

    # Websocket API session manager
    @@session_manager : Session::Manager? = nil

    # Core service discovery
    class_getter core_discovery = HoundDog::Discovery.new(CORE_NAMESPACE)

    # Strong params for index method
    class IndexParams < Params
      attribute zone_id : String
      attribute module_id : String
      attribute features : String
      attribute capacity : Int32
      attribute bookable : Bool
    end

    # Query ControlSystem resources
    def index
      elastic = Model::ControlSystem.elastic
      query = Model::ControlSystem.elastic.query(params)
      args = IndexParams.new(params)

      # Filter systems via zone_id
      if zone_id = args.zone_id
        query.must({
          "zones" => [zone_id],
        })
      end

      # Filter via module_id
      if module_id = args.module_id
        query.must({
          "modules" => [module_id],
        })
      end

      # Filter by features
      if features = args.features
        features = features.split(',')
        query.must({
          "features" => features,
        })
      end

      # filter by capacity
      if capacity = args.capacity
        query.range({
          "capacity" => {
            :gte => capacity,
          },
        })
      end

      # filter by bookable
      bookable = args.bookable
      if !bookable.nil?
        query.must({
          "bookable" => [bookable],
        })
      end

      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    # Renders a control system
    def show
      if params["complete"]?
        render json: with_fields(current_system, {
          :module_data => current_system.module_data,
          :zone_data   => current_system.zone_data,
        })
      else
        render json: current_system
      end
    end

    class UpdateParams < Params
      attribute version : Int32, presence: true
    end

    # Updates a control system
    def update
      version = begin
        args = UpdateParams.new(params).validate!
        args.version.not_nil!
      rescue
        message = "missing system version parameter"
        respond_with(:precondition_failed) do
          text message
          json({error: message})
        end
      end

      control_system = current_system
      if version != control_system.version
        message = "attempting to edit an old version"
        respond_with(:conflict) do
          text message
          json({error: message})
        end
      end

      control_system.assign_attributes_from_json(request.body.as(IO))
      control_system.version = version + 1

      save_and_respond(control_system)
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:sys_id", :update_alt { update }

    def create
      save_and_respond Model::ControlSystem.from_json(request.body.as(IO))
    end

    def destroy
      current_system.destroy
      head :ok
    end

    # Return all zones for this system
    #
    get "/:sys_id/zones" do
      zones = current_system.zones || [] of String

      # Save the DB hit if there are no zones on the system
      documents = if zones.empty?
                    [] of Model::Zone
                  else
                    Model::Zone.get_all(zones).to_a
                  end

      response_size = documents.size
      response.headers["X-Total-Count"] = response_size.to_s
      response.headers["Content-Range"] = "#{Model::Zone.table_name} 0-#{response_size}/#{response_size}"
      render json: documents
    end

    # Receive the collated settings for a system
    #
    get("/:sys_id/settings", :settings) do
      render json: Api::Settings.collated_settings(current_user, current_system)
    end

    # Adds the module from the system if it doesn't already exist
    #
    put("/:sys_id/module/:module_id", :add_module) do
      control_system = current_system
      module_id = params["module_id"]
      modules = control_system.modules
      control_system_id = control_system.id.as(String)

      head :not_found unless Model::Module.exists?(module_id)

      module_present = modules.try(&.includes?(module_id)) || Model::ControlSystem.add_module(control_system_id, module_id)

      unless module_present
        render text: "Failed to add ControlSystem Module", status: :internal_server_error
      end

      # Return the latest version of the control system
      render json: Model::ControlSystem.find!(control_system_id, runopts: {"read_mode" => "majority"})
    end

    # Removes the module from the system and deletes it if not used elsewhere
    #
    delete("/:sys_id/module/:module_id", :remove_module) do
      control_system = current_system
      module_id = params["module_id"]
      modules = control_system.modules
      control_system_id = control_system.id.as(String)

      module_removed = !modules.try(&.includes?(module_id)) || Model::ControlSystem.remove_module(control_system_id, module_id)

      unless module_removed
        render text: "Failed to remove ControlSystem Module", status: :internal_server_error
      end

      # Return the latest version of the control system
      render json: Model::ControlSystem.find!(control_system_id, runopts: {"read_mode" => "majority"})
    end

    # Module Functions
    ###########################################################################

    # Start modules
    #
    post("/:sys_id/start", :start) do
      Systems.module_running_state(running: true, control_system: current_system)

      head :ok
    end

    # Stop modules
    #
    post("/:sys_id/stop", :stop) do
      Systems.module_running_state(running: false, control_system: current_system)

      head :ok
    end

    # Toggle the running state of ControlSystem's Module
    #
    protected def self.module_running_state(control_system : Model::ControlSystem, running : Bool)
      modules = control_system.modules || [] of String
      Model::Module.table_query do |q|
        q
          .get_all(modules)
          .filter({ignore_startstop: false})
          .update({running: running})
      end
    end

    # Driver Metadata, State and Status
    ###########################################################################

    # Runs a function in a system module
    #
    post("/:sys_id/:module_slug/:method", :execute) do
      sys_id, module_slug, method = params["sys_id"], params["module_slug"], params["method"]
      module_name, index = RemoteDriver.get_parts(module_slug)
      args = Array(JSON::Any).from_json(request.body.as(IO))

      remote_driver = RemoteDriver.new(
        sys_id: sys_id,
        module_name: module_name,
        index: index,
        discovery: Systems.core_discovery
      )

      ret_val = remote_driver.exec(
        security: driver_clearance(user_token),
        function: method,
        args: args,
        request_id: request_id,
      )
      response.headers["Content-Type"] = "application/json"
      render text: ret_val
    rescue e : RemoteDriver::Error
      handle_execute_error(e)
    rescue e
      Log.error(exception: e) { {message: "core execute request failed", sys_id: sys_id, module_name: module_name} }
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Look-up a module types in a system, returning a count of each type
    #
    get("/:sys_id/types", :types) do
      modules = Model::Module.in_control_system(current_system.id.as(String))
      types = modules.each_with_object(Hash(String, Int32).new(0)) do |mod, count|
        count[mod.resolved_name.as(String)] += 1
      end

      render json: types
    end

    # Returns the state of an associated module
    #
    get("/:sys_id/:module_slug", :state) do
      sys_id, module_slug = params["sys_id"], params["module_slug"]
      module_name, index = RemoteDriver.get_parts(module_slug)

      render json: module_state(sys_id, module_name, index)
    end

    # Returns the state lookup for a given key on a module
    #
    get("/:sys_id/:module_slug/:key", :state_lookup) do
      sys_id, key, module_slug = params["sys_id"], params["key"], params["module_slug"]
      module_name, index = RemoteDriver.get_parts(module_slug)

      render json: module_state(sys_id, module_name, index, key)
    end

    # Lists functions available on the driver
    # Filters higher privilege functions.
    get("/:sys_id/functions/:module_slug", :functions) do
      sys_id, module_slug = params["sys_id"], params["module_slug"]
      module_name, index = RemoteDriver.get_parts(module_slug)
      metadata = ::PlaceOS::Driver::Proxy::System.driver_metadata?(
        system_id: sys_id,
        module_name: module_name,
        index: index,
      )

      unless metadata
        Log.debug { "metadata not found for #{module_slug} on #{sys_id}" }
        head :not_found
      end

      hidden_functions = if user_token.is_admin?
                           # All functions available to admin
                           [] of String
                         elsif user_token.is_support?
                           # Admin functions hidden from support
                           metadata.security["administrator"]? || [] of String
                         else
                           # All privileged functions hidden from user without privileges
                           (metadata.security["support"]? || [] of String) + (metadata.security["administrator"]? || [] of String)
                         end

      # Delete keys to metadata for functions with higher privilege
      functions = metadata.functions.reject!(hidden_functions)

      # Transform function metadata
      response = functions.transform_values do |arguments|
        {
          arity:  arguments.size,
          params: arguments,
          order:  arguments.keys,
        }
      end

      render json: response
    end

    def module_state(sys_id : String, module_name : String, index : Int32, key : String? = nil)
      # Look up module's id for module on system
      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(
        system_id: sys_id,
        module_name: module_name,
        index: index
      )

      if module_id
        # Grab drive(r state proxy
        storage = PlaceOS::Driver::Storage.new(module_id)
        # Perform lookup, otherwise dump state
        key ? storage[key] : storage.to_h
      end
    end

    # Websocket API
    ###########################################################################

    ws("/control", :control) do |ws|
      Log.debug { "WebSocket API request" }
      Systems.session_manager.create_session(
        ws: ws,
        request_id: request_id,
        user: user_token,
      )
    end

    # Helpers
    ###########################################################################

    # Use consistent hashing to determine the location of the module
    def self.locate_module(module_id : String) : URI
      node = @@core_discovery.find?(module_id)
      raise "no core instances registered!" unless node
      node[:uri]
    end

    # Determine URI for a system module
    def self.locate_module?(sys_id : String, module_name : String, index : Int32) : URI?
      module_id = ::PlaceOS::Driver::Proxy::System.module_id?(sys_id, module_name, index)
      module_id.try &->self.locate_module(String)
    end

    # Create a core client for given module id
    def self.core_for(module_id : String, request_id : String? = nil) : Core::Client
      Core::Client.new(uri: self.locate_module(module_id), request_id: request_id)
    end

    # Create a core client and yield it to a block
    def self.core_for(module_id : String, request_id : String? = nil, & : Core::Client -> V) forall V
      Core::Client.client(uri: self.locate_module(module_id), request_id: request_id) do |client|
        yield client
      end
    end

    # Lazy initializer for session_manager
    def self.session_manager
      (@@session_manager ||= Session::Manager.new(@@core_discovery)).as(Session::Manager)
    end

    def current_system : Model::ControlSystem
      control_system || find_system
    end

    def find_system
      # Find will raise a 404 (not found) if there is an error
      @control_system = Model::ControlSystem.find!(params["sys_id"], runopts: {"read_mode" => "majority"})
    end
  end
end