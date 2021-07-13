require "hound-dog"
require "placeos-core/client"
require "promise"

require "./application"
require "./systems"

module PlaceOS::Api
  class Edges < Application
    base "/api/engine/v2/edges/"

    before_action :check_admin, except: [:index, :show, :edge]
    before_action :check_support, only: [:index, :show]

    before_action :current_edge, only: [:destroy, :drivers, :show, :update, :update_alt, :token]
    before_action :body, only: [:create, :update, :update_alt]

    skip_action :authorize!, only: [:edge]
    skip_action :set_user_id, only: [:edge]
    skip_action :check_oauth_scope, only: [:edge]

    getter current_edge : Model::Edge { find_edge }

    class_getter connection_manager : ConnectionManager { ConnectionManager.new(core_discovery) }

    # Validate the present of the id and check the secret before routing to core
    ws("/control", :edge) do |socket|
      token = params["token"]?

      return render_error(HTTP::Status::BAD_REQUEST, "Missing 'token' param") if token.nil? || token.presence.nil?

      edge_id = Model::Edge.validate_token?(token)

      head status: :unauthorized if edge_id.nil?

      Log.info { {edge_id: edge_id, message: "new edge connection"} }

      Edges.connection_manager.add_edge(edge_id, socket)
    end

    get("/:id/token", :token) do
      head :forbidden unless is_admin?
      render json: {token: current_edge.token(current_user)}
    end

    def index
      elastic = Model::Edge.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)
      render json: paginate_results(elastic, query)
    end

    def show
      render json: current_edge
    end

    def update
      current_edge.assign_attributes_from_json(self.body)
      save_and_respond current_edge
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond(Model::Edge.from_json(self.body))
    end

    def destroy
      current_edge.destroy
      head :ok
    end

    # Helpers
    ###########################################################################

    protected def find_edge
      id = params["id"]
      Log.context.set(edge_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Edge.find!(id, runopts: {"read_mode" => "majority"})
    end

    # Edge Connection Management
    ###########################################################################

    # Handles the websocket proxy between Edge and Core
    #
    # TODO: Use a single socket per core
    class ConnectionManager
      Log = ::Log.for(self)

      private getter edge_mapping = {} of String => HoundDog::Service::Node
      private getter edge_sockets = {} of String => HTTP::WebSocket
      private getter core_sockets = {} of String => HTTP::WebSocket

      private getter edge_lock = Mutex.new(protection: :reentrant)

      getter core_discovery : Api::Discovery::Core

      def initialize(@core_discovery : Api::Discovery::Core)
        @core_discovery.callbacks << ->rebalance(Array(HoundDog::Service::Node))
      end

      def add_edge(edge_id : String, socket : HTTP::WebSocket)
        Log.debug { {edge_id: edge_id, message: "adding edge socket"} }
        edge_lock.synchronize do
          edge_sockets[edge_id] = socket
          add_core(edge_id, current_node: core_discovery.find(edge_id))
        end

        spawn(same_thread: true) do
          loop do
            socket.ping rescue break
            sleep 30
          end
        end

        socket.on_close { remove(edge_id) }
      rescue e
        Log.error(exception: e) { {edge_id: edge_id, message: "while adding edge socket"} }
        remove(edge_id)
        socket.close
      end

      def remove(edge_id : String)
        edge_lock.synchronize do
          mapping = edge_mapping.delete(edge_id)
          uri = mapping.try &.[:uri].to_s

          if socket = core_sockets.delete(edge_id)
            socket.close rescue nil
            Log.info { {message: "closed socket to core", edge_id: edge_id, core_uri: uri} }
          end

          if socket = edge_sockets.delete(edge_id)
            socket.close rescue nil
            Log.info { {message: "closed socket to edge", edge_id: edge_id, core_uri: uri} }
          end
        end
      end

      def add_core(
        edge_id : String,
        rendezvous : RendezvousHash = core_discovery.rendezvous,
        current_node : HoundDog::Service::Node? = nil,
        reconnect : Bool = false
      )
        node = rendezvous[edge_id]?.try &->HoundDog::Discovery.from_hash_value(String)

        raise "no core found" if node.nil?

        # No need to change connection
        if !reconnect && core_sockets.has_key?(edge_id) && current_node && node[:name] == current_node[:name]
          return
        end

        Log.debug { {edge_id: edge_id, message: "adding core socket"} }

        uri = node[:uri]
        uri.query = "edge_id=#{edge_id}"
        uri.path = "/api/core/v1/edge/control"

        socket = edge_lock.synchronize do
          edge_socket = edge_sockets[edge_id]
          core_socket = HTTP::WebSocket.new(uri)
          core_socket.on_close do
            begin
              Retriable.retry(
                max_interval: 5.seconds,
                max_elapsed_time: 1.minute,
                on_retry: ->(error : Exception, _i : Int32, _e : Time::Span, _p : Time::Span) {
                  Log.warn { {error: error.to_s, edge_id: edge_id, message: "reconnecting edge to core"} }
                }) do
                add_core(edge_id, reconnect: true) if edge_mapping.has_key?(edge_id)
              end
            rescue error
              Log.error { {
                message:  "failed to reconnect to core",
                edge_id:  edge_id,
                core_uri: edge_mapping[edge_id]?.try &.[:uri].to_s,
              } }
              remove(edge_id)
            end
          end

          # Link core to edge
          core_socket.on_message { |message|
            Log.debug { {message: "from core", packet: message} }
            edge_socket.send(message)
          }
          core_socket.on_binary { |bytes| edge_socket.stream &.write(bytes) }

          # Link edge to core
          edge_socket.on_message { |message|
            Log.debug { {message: "from edge", packet: message} }
            core_socket.send(message)
          }

          edge_socket.on_binary { |bytes| core_socket.stream &.write(bytes) }

          core_sockets[edge_id]?.try(&.close) rescue nil
          core_sockets[edge_id] = core_socket
          core_socket
        end

        Log.debug { {edge_id: edge_id, message: "successfully added edge to core connection"} }

        spawn(same_thread: true) do
          begin
            socket.run
          rescue e
            Log.error(exception: e) { "core websocket failure" }
          end
        end

        Fiber.yield
        socket
      end

      def rebalance(nodes : Array(HoundDog::Service::Node))
        Log.info { "rebalancing edge connections" }

        rendezvous = RendezvousHash.new(nodes.map(&->HoundDog::Discovery.to_hash_value(HoundDog::Service::Node)))

        edge_lock.synchronize do
          # Asynchronously refresh core connections
          Promise.map(edge_mapping) do |(edge_id, core_node)|
            begin
              Retriable.retry(max_interval: 1.seconds, max_elapsed_time: 20.seconds, on_retry: ->(e : Exception, _i : Int32, _e : Time::Span, _p : Time::Span) {
                Log.warn { {error: e.to_s, edge_id: edge_id, message: "retrying connection to core"} }
              }) do
                add_core(edge_id, current_node: core_node, rendezvous: rendezvous)
              end
            rescue error
              Log.error(exception: error) { {message: "failed to connect to core", edge_id: edge_id} }
              remove(edge_id)
            end
          end.get
        end
      end
    end
  end
end
