require "../helper"

module PlaceOS::Api
  describe Users do
    authenticated_user, authorization_header = authentication
    base = Users::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::User.table_name, headers: authorization_header)

      describe "CRUD operations", tags: "crud" do
        it "show" do
          model = Model::Generator.user.save!
          model.persisted?.should be_true
          id = model.id.as(String)
          result = curl(
            method: "GET",
            path: base + id,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id

          model.destroy
        end

        it "show via email" do
          model = Model::Generator.user.save!
          model.persisted?.should be_true
          id = model.id.as(String)
          result = curl(
            method: "GET",
            path: base + model.email,
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_model = Model::User.from_trusted_json(result.body)
          response_model.id.should eq id
          response_model.email.should eq model.email

          model.destroy
        end

        describe "update" do
          it "updates groups" do
            initial_groups = ["public"]

            model = Model::Generator.user
            model.groups = initial_groups
            model.save!
            model.persisted?.should be_true

            updated_groups = ["admin", "public", "calendar"]

            id = model.id.as(String)
            result = curl(
              method: "PATCH",
              path: base + id,
              body: {groups: updated_groups}.to_json,
              headers: authorization_header.merge({"Content-Type" => "application/json"})
            )

            result.status_code.should eq 200
            response_model = Model::User.from_trusted_json(result.body)
            response_model.id.should eq id
            response_model.groups.should eq updated_groups

            model.destroy
          end
        end
      end

      describe "/current" do
        it "renders the current user" do
          result = curl(
            method: "GET",
            path: File.join(base, "/current"),
            headers: authorization_header,
          )

          result.status_code.should eq 200
          response_user = Model::User.from_trusted_json(result.body)
          response_user.id.should eq authenticated_user.id
        end
      end
    end
  end
end
