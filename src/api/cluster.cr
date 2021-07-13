require "promise"
require "./application"

require "placeos-core/client"

module PlaceOS::Api
  class Cluster < Application
    base "/api/engine/v2/cluster/"
    before_action :check_admin

    class ClusterParams < Params
      attribute include_status : Bool = false
    end

    def index
      details = self.class.core_discovery.node_hash
      arguments = ClusterParams.new(params)

      if arguments.include_status
        promises = details.map do |core_id, uri|
          Promise.defer do
            Cluster.node_status(core_id, uri, request_id)
          end
        end

        # [
        #   {
        #     "load": <load>,
        #     "status": <status>,
        #     "uri": <uri>,
        #     "id": <id>
        #   },
        #   ...
        # ]
        render json: Promise.all(promises).get.compact
      else
        # [ { "uri": <uri>, "id": <id> }, ... ]
        details = details.map { |id, uri| {id: id, uri: uri} }
        render json: details
      end
    end

    alias NodeStatus = NamedTuple(
      id: String,
      uri: URI,
      # Get the cluster load
      load: PlaceOS::Core::Client::Load?,
      # Get the cluster details (number of drivers running, errors etc)
      status: PlaceOS::Core::Client::CoreStatus?,
    )

    def self.node_status(core_id : String, uri : URI, request_id : String) : NodeStatus?
      Core::Client.client(uri, request_id) do |client|
        {
          id:  core_id,
          uri: uri,
          # Get the cluster load
          load: client.core_load,
          # Get the cluster details (number of drivers running, errors etc)
          status: client.core_status,
        }
      end
    rescue e
      Log.warn(exception: e) { {message: "failed to request core status", uri: uri.to_s, core_id: core_id} }
      nil
    end

    # Collect unique driver keys managed by a core node
    #
    def self.collect_keys(loaded : PlaceOS::Core::Client::Loaded)
      loaded.edge
        .flat_map(&.last.keys)        # Extract driver keys from each edge bound to the core
        .concat(loaded.local.keys)    # Extract driver keys from the core
        .map!(&.rpartition('/').last) # Strip any path prefix, retaining only the driver key
        .to_set
    end

    def show
      core_id = params["id"]
      args = ClusterParams.new(params)
      uri = self.class.core_discovery.node_hash[core_id]?

      Log.context.set({core_id: core_id, uri: uri.try &.to_s, include_status: args.include_status})

      if uri.nil?
        Log.debug { "core not registered" }
        head :not_found
      end

      Core::Client.client(uri, request_id) do |client|
        loaded = client.loaded

        # Collect unique driver keys managed by node
        driver_keys = Cluster.collect_keys(loaded)

        Log.debug { {loaded: loaded.to_json} }

        if args.include_status
          promises = driver_keys.map do |key|
            Promise.defer do
              driver_status = begin
                client.driver_status(key)
              rescue e
                Log.warn(exception: e) { {
                  message:    "failed to request driver status",
                  driver_key: key,
                } }
                nil
              end

              Cluster.driver_status(key, loaded, driver_status) unless driver_status.nil?
            end
          end

          # [
          #   {
          #     "driver": "<driver_key>",
          #     "local": { "modules": [<module_id>], "status": <driver_status> }
          #     "edge": {
          #       <edge_id>: { "modules": [<module_id>], "status": <driver_status> }
          #     }
          #   }
          # ]
          render json: Promise.all(promises).get.compact
        else
          # [
          #   {
          #     "driver": "<driver_key>",
          #     "local": { "modules": [<module_id>] }
          #     "edge": {
          #       <edge_id>: { "modules": [<module_id>] }
          #     }
          #   }
          # ]
          render json: driver_keys.map { |key| Cluster.driver_status(key, loaded) }
        end
      end
    end

    alias Driver = NamedTuple(modules: Array(String), status: PlaceOS::Core::Client::DriverStatus::Metadata?)
    alias DriverStatus = NamedTuple(driver: String, local: Driver, edge: Hash(String, Driver))

    def self.driver_status(
      key : String,
      loaded : PlaceOS::Core::Client::Loaded,
      status : PlaceOS::Core::Client::DriverStatus? = nil
    ) : DriverStatus
      edge_modules = loaded.edge
      local_modules = loaded.local

      edges = edge_modules.map do |edge_id, processes|
        {
          edge_id, {
            modules: processes[key]? || [] of String,
            status:  status.try(&.edge[edge_id]?),
          }.as(Driver),
        }
      end.to_h

      {
        driver: key,
        local:  {
          modules: local_modules[key]? || [] of String,
          status:  status.try(&.local),
        }.as(Driver),
        edge: edges,
      }
    end

    def destroy
      core_id = params["id"]
      driver = params["driver"]

      uri = self.class.core_discovery.node_hash[core_id]
      if Core::Client.client(uri, request_id, &.terminate(driver))
        head :ok
      else
        head :not_found
      end
    end
  end
end

class URI
  def to_json(json : JSON::Builder)
    json.string to_s
  end
end
