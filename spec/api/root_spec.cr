require "../helper"

module PlaceOS::Api
  describe Root do
    Spec.before_each do
      WebMock.reset
      WebMock.allow_net_connect = true

      # Mock etcd response for core nodes request
      WebMock.stub(:post, "http://etcd:2379/v3beta/kv/range")
        .with(body: "{\"key\":\"c2VydmljZS9jb3JlLw==\",\"range_end\":\"c2VydmljZS9jb3JlMA==\"}", headers: {"Content-Type" => "application/json"})
        .to_return(body: {
          count: "1",
          kvs:   [{
            key:   "c2VydmljZS9jb3JlLw==",
            value: Base64.strict_encode("http://127.0.0.1:9001"),
          }],
        }.to_json)
    end

    with_server do
      _, authorization_header = authentication
      base = Api::Root::NAMESPACE[0]

      it "responds to health checks" do
        result = curl("GET", base, headers: authorization_header)
        result.status_code.should eq 200
      end

      it "renders version" do
        result = curl("GET", File.join(base, "version"), headers: authorization_header)
        result.status_code.should eq 200
        response = PlaceOS::Model::Version.from_json(result.body)

        response.service.should eq APP_NAME
        response.version.should eq VERSION
        response.build_time.should eq BUILD_TIME
        response.commit.should eq BUILD_COMMIT
      end

      it "constructs service versions" do
        WebMock.allow_net_connect = false

        # mock endpoints for service versions
        WebMock
          .stub(:get, "triggers:3000/api/triggers/v2/version").to_return(body: %({"service":"triggers", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "127.0.0.1:3000/api/frontends/v1/version").to_return(body: %({"service":"frontends", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "127.0.0.1:9001/api/core/v1/version").to_return(body: %({"service":"core", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "rubber-soul:3000/api/rubber-soul/v1/version").to_return(body: %({"service":"rubber_soul", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))
        WebMock
          .stub(:get, "dispatch:3000/api/server/version").to_return(body: %({"service":"dispatch", "commit":"DEV", "version":"1", "build_time":"Tue Jun 01 01:00:00 UTC 2021", "platform_version":"DEV"}))

        versions = Root.construct_versions
        versions.size.should eq(Root::SERVICES.size)
        versions.map(&.service.gsub('-', '_')).sort!.should eq Root::SERVICES.sort
      end

      describe "signal" do
        it "writes an arbitrary payload to a redis subscription" do
          subscription_channel = "test"
          channel = Channel(String).new
          subs = PlaceOS::Driver::Subscriptions.new

          _subscription = subs.channel subscription_channel do |_, message|
            channel.send(message)
          end

          params = HTTP::Params{"channel" => subscription_channel}
          result = curl("POST", File.join(base, "signal?#{params}"), body: "hello", headers: authorization_header)
          result.status_code.should eq 200

          begin
            select
            when message = channel.receive
              message.should eq "hello"
            when timeout 2.seconds
              raise "timeout"
            end
          ensure
            subs.terminate
          end
        end

        it "validates presence of `channel` param" do
          result = curl("POST", File.join(base, "signal"), body: "hello", headers: authorization_header)
          result.status_code.should eq 400
        end

        it "prevents access to non-guest channels for guests" do
          _, guest_header = authentication(["guest"])
          result = curl("POST", File.join(base, "signal?channel=dummy"), body: "hello", headers: guest_header)
          result.status_code.should eq 403
        end

        it "allows access to guest channels for guests" do
          _, guest_header = authentication(["guest"])

          subscription_channel = "/guest/dummy"
          channel = Channel(String).new
          subs = PlaceOS::Driver::Subscriptions.new

          _subscription = subs.channel subscription_channel do |_, message|
            channel.send(message)
          end

          params = HTTP::Params{"channel" => subscription_channel}
          result = curl("POST", File.join(base, "signal?#{params}"), body: "hello", headers: guest_header)
          result.status_code.should eq 200

          begin
            select
            when message = channel.receive
              message.should eq "hello"
            when timeout 2.seconds
              raise "timeout"
            end
          ensure
            subs.terminate
          end
        end
      end
    end
  end
end
