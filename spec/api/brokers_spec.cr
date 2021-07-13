require "../helper"

module PlaceOS::Api
  describe Brokers do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Brokers::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Broker.table_name, headers: authorization_header)

      pending "index", tags: "search" do
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(Model::Broker, Brokers)

        it "update" do
          broker = Model::Generator.broker.save!
          original_name = broker.name
          broker.name = UUID.random.to_s

          id = broker.id.as(String)
          path = base + id
          result = curl(
            method: "PATCH",
            path: path,
            body: broker.changed_attributes.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Broker.from_trusted_json(result.body)

          updated.id.should eq broker.id
          updated.name.should_not eq original_name
        end
      end
    end
  end
end
