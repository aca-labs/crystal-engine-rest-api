require "../helper"
require "timecop"

module PlaceOS::Api
  describe SystemTriggers do
    _, authorization_header = authentication
    base = SystemTriggers::NAMESPACE[0]

    with_server do
      test_404(
        base.gsub(/:sys_id/, "sys-#{Random.rand(9999)}"),
        model_name: Model::TriggerInstance.table_name,
        headers: authorization_header,
      )

      describe "index", tags: "search" do
        it "as_of query" do
          sys = Model::Generator.control_system.save!
          path = base.gsub(/:sys_id/, sys.id)

          inst1 = Model::Generator.trigger_instance
          inst1.control_system = sys
          Timecop.freeze(2.days.ago) do
            inst1.save!
          end
          inst1.persisted?.should be_true

          inst2 = Model::Generator.trigger_instance
          inst2.control_system = sys
          inst2.save!
          inst2.persisted?.should be_true

          refresh_elastic(Model::TriggerInstance.table_name)

          params = HTTP::Params.encode({"as_of" => (inst1.updated_at.try &.to_unix).to_s})
          path = "#{path}?#{params}"
          correct_response = until_expected("GET", path, authorization_header) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            contains_correct = results.any?(inst1.id)
            contains_incorrect = results.any?(inst2.id)

            !results.empty? && contains_correct && !contains_incorrect
          end

          correct_response.should be_true
        end
      end

      describe "CRUD operations", tags: "crud" do
        it "create" do
          sys = Model::Generator.control_system.save!
          trigger_instance = Model::Generator.trigger_instance
          trigger_instance.control_system = sys
          body = trigger_instance.to_json

          path = base.gsub(/:sys_id/, sys.id)
          result = curl(
            method: "POST",
            path: path,
            body: body,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 201
          body = result.body.not_nil!
          Model::TriggerInstance.find(JSON.parse(body)["id"].as_s).try &.destroy
        end

        it "show" do
          sys = Model::Generator.control_system.save!
          trigger_instance = Model::Generator.trigger_instance
          trigger_instance.control_system = sys
          trigger_instance.save!
          id = trigger_instance.id.not_nil!

          path = base.gsub(/:sys_id/, sys.id) + id
          result = curl(method: "GET", path: path, headers: authorization_header)

          result.status_code.should eq 200

          response_model = Model::TriggerInstance.from_trusted_json(result.body)
          response_model.id.should eq id

          sys.destroy
          trigger_instance.destroy
        end

        it "update" do
          sys = Model::Generator.control_system.save!
          trigger_instance = Model::Generator.trigger_instance
          trigger_instance.control_system = sys
          trigger_instance.save!

          original_importance = trigger_instance.important
          updated_importance = !original_importance

          id = trigger_instance.id.not_nil!
          path = base.gsub(/:sys_id/, sys.id) + id

          result = curl(
            method: "PATCH",
            path: path,
            body: {important: updated_importance}.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::TriggerInstance.from_trusted_json(result.body)

          updated.id.should eq trigger_instance.id
          updated.important.should_not eq original_importance
          updated.destroy
        end

        it "destroy" do
          sys = PlaceOS::Model::Generator.control_system.save!
          model = PlaceOS::Model::Generator.trigger_instance
          model.control_system = sys

          model.save!
          model.persisted?.should be_true

          id = model.id.not_nil!
          path = base.gsub(/:sys_id/, sys.id) + id

          result = curl(method: "DELETE", path: path, headers: authorization_header)
          result.status_code.should eq 200

          Model::TriggerInstance.find(id.as(String)).should be_nil
        end
      end
    end
  end
end
