require "promise"

require "./application"

module PlaceOS::Api
  class Metadata < Application
    # NOTE:: this API shares the base zones route
    base "/api/engine/v2/metadata"

    before_action :check_delete_permissions, only: :destroy

    before_action :current_zone, only: :children

    # Allow unscoped read access to metadata
    skip_action :check_oauth_scope, only: [:show, :children_metadata]

    getter current_zone : Model::Zone { find_zone }

    # Fetch metadata for a model
    #
    # Filter for a specific metadata by name via `name` param
    def show
      parent_id = params["id"]
      name = params["name"]?

      # Guest JWTs include the control system id that they have access to
      if user_token.scope.includes?("guest")
        head :forbidden unless name && guest_ids.includes?(parent_id)
      end

      render json: Model::Metadata.build_metadata(parent_id, name)
    end

    # Fetch metadata for Zone children
    #
    # Filter for a specific metadata by name via `name` param.
    # Includes the parent metadata by default via `include_parent` param.
    get "/:id/children", :children_metadata do
      parent_id = params["id"]
      name = params["name"]?

      # Guest JWTs include the control system id that they have access to
      if user_token.scope.includes?("guest")
        head :forbidden unless name && guest_ids.includes?(parent_id)
      end

      include_parent = if (_include = params["include_parent"]?)
                         _include == "true"
                       else
                         true
                       end

      children = current_zone.children.all
      filtered = include_parent ? children : children.reject { |z| z.id == parent_id }

      results = filtered.map do |zone|
        {
          zone:     zone,
          metadata: Model::Metadata.build_metadata(zone, name),
        }
      end

      render json: results.to_a
    end

    # ameba:disable Metrics/CyclomaticComplexity
    def update
      parent_id = params["id"]
      metadata = Model::Metadata::Interface.from_json(request.body.as(IO))

      # We need a name to lookup the metadata
      head :bad_request if metadata.name.empty?

      meta = Model::Metadata.for(parent_id, metadata.name).first?

      if meta
        # Check if the current user has access
        raise Error::Forbidden.new unless is_support? || parent_id == user_token.id || (meta.editors & Set.new(user_token.user.roles)).size > 0

        # only support+ users can edit the editors list
        editors = metadata.editors
        meta.editors = editors if editors && is_support?

        # Update existing Metadata
        meta.description = metadata.description
        meta.details = metadata.details
      else
        # When creating a new metadata, must be at least a support user
        raise Error::Forbidden.new unless is_support? || parent_id == user_token.id

        # TODO: Check that the parent exists
        # Create new Metadata
        meta = Model::Metadata.new(
          name: metadata.name,
          details: metadata.details,
          parent_id: parent_id,
          description: metadata.description,
          editors: metadata.editors || Set(String).new,
        )
      end

      response, status = save_and_status(meta)

      if status.ok? && response.is_a?(Model::Metadata)
        render json: Model::Metadata.interface(response), status: status
      else
        render json: response, status: status
      end
    end

    put "/:id", :update_alt { update }

    def destroy
      parent_id = params["id"]
      name = params["name"]?
      head :bad_request unless name

      Model::Metadata.for(parent_id, name).each &.destroy

      head :ok
    end

    # Helpers
    ###########################################################################

    def find_zone
      id = params["id"]
      Log.context.set(zone_id: id)
      # Find will raise a 404 (not found) if there is an error
      Model::Zone.find!(id)
    end

    # Fetch zones for system the current user has a role for
    def guest_ids
      sys_id = user_token.user.roles.last
      Model::ControlSystem.find!(sys_id, runopts: {"read_mode" => "majority"}).zones + [sys_id]
    end

    # Does the user making the request have permissions to modify the data
    def check_delete_permissions
      raise Error::Forbidden.new unless is_support? || params["id"] == user_token.id
    end
  end
end
