require "../helper"

module PlaceOS::Api
  describe Drivers do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Drivers::NAMESPACE[0]

    with_server do
      describe "index", tags: "search" do
        test_base_index(klass: Model::Driver, controller_klass: Drivers)
        it "filters queries by driver role" do
          service = Model::Generator.driver(role: Model::Driver::Role::Service)
          service.name = UUID.random.to_s
          service.save!

          params = HTTP::Params.encode({
            "role" => Model::Driver::Role::Service.to_i.to_s,
            "q"    => service.name,
          })

          refresh_elastic(Model::Driver.table_name)
          path = "#{base}?#{params}"
          found = until_expected("GET", path, authorization_header) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body)
            all_service_roles = results.all? { |r| r["role"] == Model::Driver::Role::Service.to_i }
            contains_search_term = results.any? { |r| r["id"] == service.id }
            !results.empty? && all_service_roles && contains_search_term
          end

          found.should be_true
        end
      end

      test_404(base, model_name: Model::Driver.table_name, headers: authorization_header)

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Driver, controller_klass: Drivers)

        describe "update" do
          it "if role is preserved" do
            driver = Model::Generator.driver.save!
            original_name = driver.name
            driver.name = UUID.random.to_s

            id = driver.id.as(String)
            path = base + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.changed_attributes.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )
            result.success?.should be_true

            updated = Model::Driver.from_trusted_json(result.body)
            updated.id.should eq driver.id
            updated.name.should_not eq original_name
          end

          it "fails if role differs" do
            driver = Model::Generator.driver(role: Model::Driver::Role::SSH).save!
            driver.role = Model::Driver::Role::Device
            id = driver.id.as(String)
            path = base + id
            result = curl(
              method: "PATCH",
              path: path,
              body: driver.changed_attributes.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.success?.should_not be_true
            result.body.should contain "role must not change"
          end
        end
      end
    end
  end
end
