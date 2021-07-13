require "promise"

require "./application"

module PlaceOS::Api
  class Zones < Application
    include Utils::CoreHelper
    base "/api/engine/v2/zones/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, except: [:index]
    before_action :current_zone, only: [:show, :update, :update_alt, :destroy]

    before_action :body, only: [:create, :update, :update_alt, :zone_execute]

    getter current_zone : Model::Zone { find_zone }

    def index
      elastic = Model::Zone.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      # Limit results to the children of this parent
      if params.has_key? "parent"
        query.must({
          "parent_id" => [params["parent"]],
        })
      end

      if params.has_key? "tags"
        # list of unique tags
        tags = params["tags"].gsub(/[^0-9a-z ]/i, "").split(',').reject(&.empty?).uniq!

        head :bad_request if tags.empty?

        query.must({
          "tags" => tags,
        })
      else
        head :forbidden unless is_support? || is_admin?

        query.search_field "name"
      end

      render json: paginate_results(elastic, query)
    end

    # BREAKING CHANGE: param key `data` used to attempt to retrieve a setting from the zone
    def show
      if params.has_key? "complete"
        # Include trigger data in response
        render json: with_fields(current_zone, {
          :trigger_data => current_zone.trigger_data,
        })
      else
        render json: current_zone
      end
    end

    def update
      current_zone.assign_attributes_from_json(self.body)
      save_and_respond current_zone
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond Model::Zone.from_json(self.body)
    end

    def destroy
      current_zone.destroy
      head :ok
    end

    private enum ExecStatus
      Success
      Failure
      Missing
    end

    # Return triggers attached to current zone
    #
    get "/:id/triggers", :trigger_instances do
      triggers = current_zone.trigger_data
      set_collection_headers(triggers.size, Model::Trigger.table_name)
      render json: triggers
    end

    record(
      ZoneExecResponse,
      success : Array(String) = [] of String,
      failure : Array(String) = [] of String,
      module_missing : Array(String) = [] of String
    ) { include JSON::Serializable }

    # Execute a method on a module across all systems in a Zone
    post "/:id/exec/:module_slug/:method", :zone_execute do
      zone_id, module_slug, method = params["id"], params["module_slug"], params["method"]
      args = Array(JSON::Any).from_json(self.body)

      # Crystal BUG: total function, it should destructure with correct types
      module_parts = Driver::Proxy::RemoteDriver.get_parts(module_slug)
      module_name, index = module_parts

      results = Promise.map(current_zone.systems) do |system|
        system_id = system.id.as(String)
        begin
          remote_driver = Driver::Proxy::RemoteDriver.new(
            sys_id: system_id,
            module_name: module_name.as(String),
            index: index.as(Int32)
          )

          output = remote_driver.exec(
            security: driver_clearance(user_token),
            function: method.as(String), # BUG: This should not require casting
            args: args,
            request_id: request_id,
          )

          Log.debug { {message: "module exec success", system_id: system_id, module_name: module_name, index: index, method: method, output: output} }

          {system_id, ExecStatus::Success}
        rescue e : Driver::Proxy::RemoteDriver::Error
          handle_execute_error(e, respond: false)
          status = e.error_code.module_not_found? ? ExecStatus::Missing : ExecStatus::Failure
          {system_id, status}
        end
      end.get.not_nil!.to_a.compact

      response_object = results.each_with_object(ZoneExecResponse.new) do |(id, status), obj|
        case status
        in ExecStatus::Success then obj.success
        in ExecStatus::Failure then obj.failure
        in ExecStatus::Missing then obj.module_missing
        end << id
      end

      render json: response_object
    rescue e
      Log.error(exception: e) { {
        message:     "core execute request failed",
        zone_id:     zone_id,
        module_name: module_name,
        index:       index,
        method:      method,
      } }
      render text: "#{e.message}\n#{e.inspect_with_backtrace}", status: :internal_server_error
    end

    # Helpers
    ###########################################################################

    protected def find_zone
      id = params["id"]
      Log.context.set(zone_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Zone.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
