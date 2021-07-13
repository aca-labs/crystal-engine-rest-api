require "../helper"
require "timecop"

module PlaceOS
  class Api::Modules
    # Mock a stateful request to Core made by Api::Modules
    def self.driver_compiled?(mod : Model::Module, request_id : String)
      true
    end
  end
end

module PlaceOS::Api
  describe Modules do
    # ameba:disable Lint/UselessAssign
    authenticated_user, authorization_header = authentication
    base = Modules::NAMESPACE[0]

    with_server do
      test_404(base, model_name: Model::Module.table_name, headers: authorization_header)

      describe "CRUD operations", tags: "crud" do
        test_crd(klass: Model::Module, controller_klass: Modules)

        it "update preserves logic module connection status" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
          mod = Model::Generator.module(driver: driver).save!

          mod.connected = false

          id = mod.id.as(String)
          path = base + id

          result = curl(
            method: "PATCH",
            path: path,
            body: mod.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Module.from_trusted_json(result.body)
          updated.id.should eq mod.id
          updated.connected.should be_true
        end

        it "update" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
          mod = Model::Generator.module(driver: driver).save!

          connected = mod.connected
          mod.connected = !connected

          id = mod.id.as(String)
          path = base + id

          result = curl(
            method: "PATCH",
            path: path,
            body: mod.to_json,
            headers: authorization_header.merge({"Content-Type" => "application/json"}),
          )

          result.status_code.should eq 200
          updated = Model::Module.from_trusted_json(result.body)
          updated.id.should eq mod.id
          updated.connected.should eq !connected
        end
      end

      describe "index", tags: "search" do
        it "queries by parent driver" do
          name = UUID.random.to_s

          driver = Model::Generator.driver
          driver.name = name
          driver.save!

          # Module name is dependent on the driver's name
          doc = Model::Generator.module(driver: driver).save!
          doc.persisted?.should be_true

          refresh_elastic(Model::Module.table_name)

          params = HTTP::Params.encode({"q" => name})
          path = "#{base.rstrip('/')}?#{params}"
          header = authorization_header
          found = until_expected("GET", path, header) do |response|
            Array(Hash(String, JSON::Any)).from_json(response.body).any? do |result|
              result["id"].as_s == doc.id
            end
          end

          found.should be_true
        end

        it "looks up by system_id" do
          mod = Model::Generator.module.save!
          sys = Model::Generator.control_system
          sys.modules = [mod.id.as(String)]
          sys.save!

          response_io = IO::Memory.new

          ctx = context("GET", base)
          ctx.route_params = {"control_system_id" => sys.id.as(String)}
          ctx.response.output = response_io

          controller = Api::Modules.new(ctx, :index)

          # Call the index method of the controller
          controller.index

          results = Array(Hash(String, JSON::Any)).from_json(ctx.response.output.to_s).map(&.["id"].as_s)
          got_one = ctx.response.headers["X-Total-Count"] == "1"
          right_one = results.first? == mod.id
          found = got_one && right_one

          found.should be_true
        end

        it "as_of query" do
          mod1 = Model::Generator.module
          mod1.connected = true
          Timecop.freeze(2.days.ago) do
            mod1.save!
          end
          mod1.persisted?.should be_true

          mod2 = Model::Generator.module
          mod2.connected = true
          mod2.save!
          mod2.persisted?.should be_true

          params = HTTP::Params.encode({"as_of" => (mod1.updated_at.try &.to_unix).to_s})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body).map(&.["id"].as_s)
            contains_correct = results.any?(mod1.id)
            contains_incorrect = results.any?(mod2.id)
            !results.empty? && contains_correct && !contains_incorrect
          end

          found.should be_true
        end

        it "connected query" do
          mod = Model::Generator.module
          mod.ignore_connected = false
          mod.connected = true
          mod.save!
          mod.persisted?.should be_true

          params = HTTP::Params.encode({"connected" => "true"})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body)

            all_connected = results.all? { |r| r["connected"].as_bool == true }
            contains_created = results.any? { |r| r["id"].as_s == mod.id }

            !results.empty? && all_connected && contains_created
          end

          found.should be_true
        end

        it "no logic query" do
          driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
          mod = Model::Generator.module(driver: driver)
          mod.role = Model::Driver::Role::Service
          mod.save!

          params = HTTP::Params.encode({"no_logic" => "true"})
          path = "#{base}?#{params}"

          found = until_expected("GET", path, authorization_header) do |response|
            results = Array(Hash(String, JSON::Any)).from_json(response.body)

            no_logic = results.all? { |r| r["role"].as_i != Model::Driver::Role::Logic.to_i }
            contains_created = results.any? { |r| r["id"].as_s == mod.id }

            !results.empty? && no_logic && contains_created
          end

          found.should be_true
        end
      end
    end

    describe "/:id/settings" do
      it "collates Module settings" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!
        driver_settings_string = %(value: 0\nscreen: 0\nfrangos: 0\nchop: 0)
        Model::Generator.settings(driver: driver, settings_string: driver_settings_string).save!

        control_system = Model::Generator.control_system.save!
        control_system_settings_string = %(frangos: 1)
        Model::Generator.settings(control_system: control_system, settings_string: control_system_settings_string).save!

        zone = Model::Generator.zone.save!
        zone_settings_string = %(screen: 1)
        Model::Generator.settings(zone: zone, settings_string: zone_settings_string).save!

        control_system.zones = [zone.id.as(String)]
        control_system.update!

        mod = Model::Generator.module(driver: driver, control_system: control_system).save!
        module_settings_string = %(value: 2\n)
        Model::Generator.settings(mod: mod, settings_string: module_settings_string).save!

        expected_settings_ids = [
          mod.master_settings,
          control_system.master_settings,
          zone.master_settings,
          driver.master_settings,
        ].flat_map(&.compact_map(&.id)).reverse!

        path = "#{base}#{mod.id}/settings"
        result = curl(
          method: "GET",
          path: path,
          headers: authorization_header,
        )

        result.success?.should be_true

        settings = Array(Hash(String, JSON::Any)).from_json(result.body)
        settings_hierarchy_ids = settings.map &.["id"].to_s

        settings_hierarchy_ids.should eq expected_settings_ids
        {mod, control_system, zone, driver}.each &.destroy
      end

      it "returns an empty array for a logic module without associated settings" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic).save!

        control_system = Model::Generator.control_system.save!

        zone = Model::Generator.zone.save!

        control_system.zones = [zone.id.as(String)]
        control_system.update!

        mod = Model::Generator.module(driver: driver, control_system: control_system).save!
        path = "#{base}#{mod.id}/settings"

        result = curl(
          method: "GET",
          path: path,
          headers: authorization_header,
        )

        unless result.success?
          puts "\ncode: #{result.status_code} body: #{result.body}"
        end

        result.success?.should be_true
        Array(JSON::Any).from_json(result.body).should be_empty
      end

      it "returns an empty array for a module without associated settings" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Service).save!
        mod = Model::Generator.module(driver: driver).save!
        path = "#{base}#{mod.id}/settings"

        result = curl(
          method: "GET",
          path: path,
          headers: authorization_header,
        )

        unless result.success?
          puts "\ncode: #{result.status_code} body: #{result.body}"
        end

        result.success?.should be_true
        Array(JSON::Any).from_json(result.body).should be_empty
      end
    end

    describe "ping" do
      it "fails for logic module" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Logic)
        mod = Model::Generator.module(driver: driver).save!
        path = "#{base}#{mod.id}/ping"
        result = curl(
          method: "POST",
          path: path,
          headers: authorization_header,
        )

        result.success?.should be_false
        result.status_code.should eq 406
      end

      it "pings a module" do
        driver = Model::Generator.driver(role: Model::Driver::Role::Device)
        driver.default_port = 8080
        driver.save!
        mod = Model::Generator.module(driver: driver)
        mod.ip = "127.0.0.1"
        mod.save!

        path = "#{base}#{mod.id}/ping"
        result = curl(
          method: "POST",
          path: path,
          headers: authorization_header,
        )

        body = JSON.parse(result.body)
        result.success?.should be_true
        body["pingable"].should be_true
      end
    end
  end
end
