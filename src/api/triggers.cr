require "./application"

module PlaceOS::Api
  class Triggers < Application
    base "/api/engine/v2/triggers/"

    before_action :check_admin, only: [:create, :update, :destroy]
    before_action :check_support, only: [:index, :show]

    before_action :current_trigger, only: [:show, :update, :update_alt, :destroy]
    before_action :ensure_json, only: [:create, :update, :update_alt]
    before_action :body, only: [:create, :update, :update_alt]

    getter current_trigger : Model::Trigger { find_trigger }

    def index
      elastic = Model::Trigger.elastic
      query = elastic.query(params)
      query.sort(NAME_SORT_ASC)

      render json: paginate_results(elastic, query)
    end

    def show
      include_instances = params["instances"]? == "true"
      render json: !include_instances ? current_trigger : with_fields(current_trigger, {
        :trigger_instances => current_trigger.trigger_instances.to_a,
      })
    end

    def update
      current_trigger.assign_attributes_from_json(self.body)
      save_and_respond(current_trigger)
    end

    # TODO: replace manual id with interpolated value from `id_param`
    put "/:id", :update_alt { update }

    def create
      save_and_respond Model::Trigger.from_json(self.body)
    end

    def destroy
      current_trigger.destroy # expires the cache in after callback
      head :ok
    end

    # Get instances associated with
    get "/:id/instances", :instances do
      instances = current_trigger.trigger_instances.to_a

      set_collection_headers(instances.size, Model::TriggerInstance.table_name)

      render json: instances
    end

    # Helpers
    ###########################################################################

    protected def find_trigger
      id = params["id"]
      Log.context.set(trigger_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Trigger.find!(id, runopts: {"read_mode" => "majority"})
    end
  end
end
