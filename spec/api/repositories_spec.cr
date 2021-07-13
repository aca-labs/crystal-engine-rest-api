require "../helper"

module PlaceOS::Api
  describe Repositories do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Repositories::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Repository.table_name, headers: authorization_header)

      describe "index", tags: "search" do
        test_base_index(Model::Repository, Repositories)
      end

      describe "CRUD operations", tags: "crud" do
        test_crd(Model::Repository, Repositories)

        it "update" do
          repository = Model::Generator.repository.save!
          original_name = repository.name
          repository.name = UUID.random.to_s

          id = repository.id.as(String)
          path = base + id
          result = curl(
            method: "PATCH",
            path: path,
            body: repository.changed_attributes.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Repository.from_trusted_json(result.body)

          updated.id.should eq repository.id
          updated.name.should_not eq original_name
        end

        describe "mutating URIs" do
          it "does not update Driver repositories with modified URIs" do
            repository = Model::Generator.repository(type: Model::Repository::Type::Driver).save!

            id = repository.id.as(String)
            path = base + id
            result = curl(
              method: "PATCH",
              path: path,
              body: {uri: "https://changed:8080"}.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.status_code.should eq 422
          end

          it "does update Interface repositories with modified URIs" do
            repository = Model::Generator.repository(type: Model::Repository::Type::Interface).save!

            id = repository.id.as(String)
            path = base + id
            result = curl(
              method: "PATCH",
              path: path,
              body: {uri: "https://changed:8080"}.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.status_code.should eq 200
          end
        end

        describe "driver only actions" do
          it "errors if enumerating drivers in an interface repo" do
            repository = Model::Generator.repository(type: Model::Repository::Type::Interface).save!

            id = repository.id.as(String)
            path = "#{base}#{id}/drivers"
            result = curl(
              method: "GET",
              path: path,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.status.should eq HTTP::Status::BAD_REQUEST
          end

          it "errors when requesting driver details from an interface repo" do
            repository = Model::Generator.repository(type: Model::Repository::Type::Interface).save!

            id = repository.id.as(String)
            path = "#{base}#{id}/details"
            result = curl(
              method: "GET",
              path: path,
              headers: authorization_header.merge({"Content-Type" => "application/json"}),
            )

            result.status.should eq HTTP::Status::BAD_REQUEST
          end
        end
      end
    end
  end
end
