require "../helper"

module PlaceOS::Api
  describe Metadata do
    base = Metadata::NAMESPACE[0]
    _, authorization_header = authentication

    with_server do
      describe "/metadata/:id/children/" do
        it "shows zone children metadata" do
          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          3.times do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            Model::Generator.metadata(parent: child.id).save!
          end

          result = curl(
            method: "GET",
            path: "#{base}/#{parent_id}/children",
            headers: authorization_header,
          )

          Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
            .from_json(result.body)
            .tap { |m| m.size.should eq(3) }
            .count(&.[:metadata].empty?.!)
            .should eq 3

          parent.destroy
        end

        it "filters zone children metadata" do
          parent = Model::Generator.zone.save!
          parent_id = parent.id.as(String)

          children = Array.new(size: 3) do
            child = Model::Generator.zone
            child.parent_id = parent_id
            child.save!
            Model::Generator.metadata(parent: child.id).save!
            child
          end

          # Create a single special metadata to filter on
          Model::Generator.metadata(name: "special", parent: children.first.id).save!

          result = curl(
            method: "GET",
            path: "#{base}/#{parent_id}/children?name=special",
            headers: authorization_header,
          )

          Array(NamedTuple(zone: JSON::Any, metadata: Hash(String, Model::Metadata::Interface)))
            .from_json(result.body)
            .count(&.[:metadata].empty?.!)
            .should eq 1

          parent.destroy
        end
      end

      describe "/metadata" do
        it "creates metadata" do
          parent = Model::Generator.zone.save!
          meta = Model::Metadata::Interface.new(
            name: "test",
            description: "",
            details: JSON.parse(%({"hello":"world","bye":"friends"})),
            parent_id: nil,
            editors: Set(String).new,
          )

          parent_id = parent.id.as(String)
          path = "#{base}/#{parent_id}"

          result = curl(
            method: "PUT",
            path: path,
            body: meta.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          new_metadata = Model::Metadata.from_json(result.body)
          found = Model::Metadata.for(parent.id.as(String), meta.name).first
          found.name.should eq new_metadata.name
        end

        it "updates metadata" do
          parent = Model::Generator.zone.save!
          meta = Model::Metadata::Interface.new(
            name: "test",
            description: "",
            details: JSON.parse(%({"hello":"world","bye":"friends"})),
            parent_id: nil,
            editors: Set(String).new,
          )

          parent_id = parent.id.as(String)
          path = "#{base}/#{parent_id}"

          result = curl(
            method: "PUT",
            path: path,
            body: meta.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          new_metadata = Model::Metadata::Interface.from_json(result.body)
          found = Model::Metadata.for(parent_id, meta.name).first
          found.name.should eq new_metadata.name

          updated_meta = Model::Metadata::Interface.new(
            name: "test",
            description: "",
            details: JSON.parse(%({"hello":"world"})),
            parent_id: nil,
            editors: Set(String).new,
          )

          result = curl(
            method: "PUT",
            path: path,
            body: updated_meta.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          update_response_meta = Model::Metadata::Interface.from_json(result.body)
          update_response_meta.details.as_h["bye"]?.should be_nil

          found = Model::Metadata.for(parent_id, meta.name).first
          found.details.as_h["bye"]?.should be_nil
        end
      end

      describe "/metadata/:id" do
        it "shows control_system metadata" do
          control_system = Model::Generator.control_system.save!
          control_system_id = control_system.id.as(String)
          meta = Model::Generator.metadata(name: "special", parent: control_system_id).save!

          result = curl(
            method: "GET",
            path: "#{base}/#{control_system_id}",
            headers: authorization_header,
          )

          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          metadata.size.should eq 1
          metadata.first[1].parent_id.should eq control_system_id
          metadata.first[1].name.should eq meta.name
        end

        it "filters control_system metadata" do
          control_system = Model::Generator.control_system.save!
          control_system_id = control_system.id.as(String)

          Model::Generator.metadata(parent: control_system_id).save!
          Model::Generator.metadata(name: "special", parent: control_system_id).save!

          result = curl(
            method: "GET",
            path: "#{base}/#{control_system_id}?name=special",
            headers: authorization_header,
          )

          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          metadata.size.should eq 1
        end

        it "shows zone metadata" do
          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)
          meta = Model::Generator.metadata(name: "special", parent: zone_id).save!

          result = curl(
            method: "GET",
            path: "#{base}/#{zone_id}",
            headers: authorization_header,
          )

          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          metadata.size.should eq 1
          metadata.first[1].parent_id.should eq zone_id
          metadata.first[1].name.should eq meta.name
        end

        it "filters zone metadata" do
          zone = Model::Generator.zone.save!
          zone_id = zone.id.as(String)

          Model::Generator.metadata(parent: zone_id).save!
          Model::Generator.metadata(name: "special", parent: zone_id).save!

          result = curl(
            method: "GET",
            path: "#{base}/#{zone_id}?name=special",
            headers: authorization_header,
          )

          metadata = Hash(String, Model::Metadata::Interface).from_json(result.body)
          metadata.size.should eq 1
        end
      end
    end
  end
end
