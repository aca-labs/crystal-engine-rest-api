require "./application"

module PlaceOS::Api
  class Settings < Application
    base "/api/engine/v2/settings/"

    before_action :check_admin, except: [:index, :show]
    before_action :check_support, only: [:index, :show]

    before_action :current_settings, only: [:show, :update, :update_alt, :destroy]
    before_action :body, only: [:create, :update, :update_alt]

    getter current_settings : Model::Settings { find_settings }

    def index
      if params.has_key? "parent_id"
        parents = params["parent_id"].split(',')

        # Directly search for model's settings
        parent_settings = Model::Settings.for_parent(parents)
        # Decrypt for the user
        parent_settings.each &.decrypt_for!(current_user)

        render json: parent_settings
      else
        elastic = Model::Settings.elastic
        query = elastic.query(params)

        render json: paginate_results(elastic, query)
      end
    end

    def show
      render json: current_settings.decrypt_for!(current_user)
    end

    def update
      current_settings.assign_attributes_from_json(self.body)

      save_and_respond(current_settings, &.decrypt_for!(current_user))
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      new_settings = Model::Settings.from_json(self.body)
      save_and_respond(new_settings, &.decrypt_for!(current_user))
    end

    def destroy
      current_settings.destroy
      head :ok
    end

    # Returns history for a particular Setting
    #
    get "/:id/history", :history do
      offset = params["offset"]?.try(&.to_i) || 0
      limit = params["limit"]?.try(&.to_i) || 15

      history = current_settings.history(offset: offset, limit: limit)

      # Privilege respecting decrypted settings history
      history.each &.decrypt_for!(current_user)

      total = Api::Settings.history_count(current_settings)
      range_start = offset
      range_end = history.size + range_start

      response.headers["X-Total-Count"] = total.to_s
      response.headers["Content-Range"] = "sets #{range_start}-#{range_end}/#{total}"

      # Set link
      if range_end < total
        params["offset"] = (range_end + 1).to_s
        params["limit"] = limit.to_s
        query_params = params.compact_map { |key, value| "#{key}=#{value}" unless key == "id" }.join("&")
        path = File.join(base_route, "/#{current_settings.id}/history")
        response.headers["Link"] = %(<#{path}?#{query_params}>; rel="next")
      end

      render json: history
    end

    # Helpers
    ###########################################################################

    # TODO: Optimise, get total query size from the response from rethinkdb
    def self.history_count(settings : Model::Settings) : Int32
      Model::Settings.table_query do |q|
        q
          .get_all([settings.parent_id.as(String)], index: :parent_id)
          .filter({settings_id: settings.id.as(String)})
          .count
      end.as_i
    end

    # Get an ordered hierarchy of Settings for the model
    #
    def self.collated_settings(user : Model::User, model : Model::ControlSystem | Model::Module)
      collated = model.settings_hierarchy.reverse!
      collated.each &.decrypt_for!(user)
      collated
    end

    protected def find_settings
      id = params["id"]
      Log.context.set(settings_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Settings.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
