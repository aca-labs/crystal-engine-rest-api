require "../helper"

module PlaceOS::Api
  describe Triggers do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Triggers::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Trigger.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        test_base_index(klass: Model::Trigger, controller_klass: Triggers)
      end

      describe "/:id/instances" do
        it "lists instances for a Trigger" do
          trigger = Model::Generator.trigger.save!
          instances = Array(Model::TriggerInstance).new(size: 3) { Model::Generator.trigger_instance(trigger).save! }

          response = curl(
            method: "GET",
            path: File.join(base, trigger.id.not_nil!, "instances"),
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          # Can't use from_json directly on the model as `id` will not be parsed
          result = Array(JSON::Any).from_json(response.body).map { |d| Model::TriggerInstance.from_trusted_json(d.to_json) }

          result.all? { |i| i.trigger_id == trigger.id }.should be_true
          instances.compact_map(&.id).sort!.should eq result.compact_map(&.id).sort!
        end
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Trigger, controller_klass: Triggers)
        it "update" do
          trigger = Model::Generator.trigger.save!
          original_name = trigger.name

          trigger.name = UUID.random.to_s

          id = trigger.id.as(String)
          path = base + id
          result = curl(
            method: "PATCH",
            path: path,
            body: trigger.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Trigger.from_trusted_json(result.body)

          updated.id.should eq trigger.id
          updated.name.should_not eq original_name
          updated.destroy
        end

        describe "show" do
          it "includes trigger_instances with truthy `instances`" do
            trigger = Model::Generator.trigger.save!
            trigger_instance = Model::Generator.trigger_instance(trigger).save!
            trigger_instance_id = trigger_instance.id.as(String)

            params = HTTP::Params{"instances" => "true"}
            path = "#{base}#{trigger.id}?#{params}"

            result = curl(
              method: "GET",
              path: path,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            response = JSON.parse(result.body)
            response["trigger_instances"].as_a?.try &.first?.try &.["id"].to_s.should eq trigger_instance_id
          end
        end
      end
    end
  end
end
