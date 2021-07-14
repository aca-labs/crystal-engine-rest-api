require "http"
require "mutex"
require "promise"
require "random"
require "rethinkdb-orm"
require "simple_retry"
require "webmock"

# Helper methods for testing controllers (curl, with_server, context)
require "../lib/action-controller/spec/curl_context"

Spec.before_suite do
  Log.builder.bind("*", backend: PlaceOS::LogBackend::STDOUT, level: :trace)
  clear_tables
end

Spec.after_suite { clear_tables }

# Application config
require "../src/config"

# Generators for Engine models
require "placeos-models/spec/generator"

require "spec"

# Configure DB
db_name = "place_#{ENV["SG_ENV"]? || "development"}"

RethinkORM.configure &.db=(db_name)

def clear_tables
  {% begin %}
    Promise.all(
      {% for t in {
                    PlaceOS::Model::ControlSystem,
                    PlaceOS::Model::Driver,
                    PlaceOS::Model::Module,
                    PlaceOS::Model::Repository,
                    PlaceOS::Model::Settings,
                    PlaceOS::Model::Trigger,
                    PlaceOS::Model::TriggerInstance,
                    PlaceOS::Model::Zone,
                  } %}
        Promise.defer { {{t.id}}.clear },
      {% end %}
    )
  {% end %}
end

AUTH_LOCK = Mutex.new

# Yield an authenticated user, and a header with Authorization bearer set
def authentication(scope = ["public"] of String)
  AUTH_LOCK.synchronize do
    test_user_email = "test-suit-rest-api@place.tech"
    existing = PlaceOS::Model::User.find_all([test_user_email], index: :email).first?

    authenticated_user = if existing
                           existing
                         else
                           user = PlaceOS::Model::Generator.user
                           user.sys_admin = true
                           user.support = true
                           user.save!
                         end
    authorization_header = {
      "Authorization" => "Bearer #{PlaceOS::Model::Generator.jwt(authenticated_user, scope).encode}",
    }
    {authenticated_user, authorization_header}
  end
end

# Check application responds with 404 when model not present
def test_404(base, model_name, headers)
  it "404s if #{model_name} isn't present in database", tags: "search" do
    id = "#{model_name}-#{Random.rand(9999).to_s.ljust(4, '0')}"
    path = base + id
    result = curl("GET", path: path, headers: headers)
    result.status_code.should eq 404
  end
end

def until_expected(method, path, headers, timeout : Time::Span = 3.seconds, &block : HTTP::Client::Response -> Bool)
  channel = Channel(Bool).new
  spawn do
    before = Time.utc
    begin
      SimpleRetry.try_to(base_interval: 50.milliseconds, max_elapsed_time: 2.seconds, retry_on: Exception) do
        result = curl(method: method, path: path, headers: headers)

        unless result.success?
          puts "\nrequest failed with: #{result.status_code}"
          puts result.body
        end

        expected = block.call(result)

        raise Exception.new("retry") unless expected || channel.closed?
        channel.send(true) if expected
      end
    rescue e
      raise e unless e.message == "retry"
    ensure
      after = Time.utc
      puts "took #{(after - before).milliseconds}ms"
    end
  end

  spawn do
    sleep timeout
    channel.close
  rescue
  end

  success = channel.receive?
  channel.close
  !!success
end

# Test search on name field
macro test_base_index(klass, controller_klass)
  {% klass_name = klass.stringify.split("::").last.underscore %}
  authenticated_user, authorization_header = authentication

  it "queries #{ {{ klass_name }} }", tags: "search" do
    name = UUID.random.to_s
    doc = PlaceOS::Model::Generator.{{ klass_name.id }}
    doc.name = name
    doc.save!

    refresh_elastic({{klass}}.table_name)

    doc.persisted?.should be_true
    params = HTTP::Params.encode({"q" => name})
    path = "#{{{controller_klass}}::NAMESPACE[0].rstrip('/')}?#{params}"
    header = authorization_header

    found = until_expected("GET", path, header) do |response|
      Array(Hash(String, JSON::Any))
        .from_json(response.body)
        .map(&.["id"].as_s)
        .any?(doc.id)
    end

    found.should be_true
  end
end

def refresh_elastic(index : String? = nil)
  path = "/_refresh"
  path = "/#{index}" + path unless index.nil?
  Neuroplastic::Client.new.perform_request("POST", path)
end

macro test_crd(klass, controller_klass)
  {% klass_name = klass.stringify.split("::").last.underscore %}
  base = {{ controller_klass }}::NAMESPACE[0]
  authenticated_user, authorization_header = authentication

  it "create" do
    body = PlaceOS::Model::Generator.{{ klass_name.id }}.to_json
    result = curl(
      method: "POST",
      path: base,
      body: body,
      headers: authorization_header.merge({"Content-Type" => "application/json"}),
    )

    result.status_code.should eq 201
    body = result.body.as(String)

    response_model = {{ klass.id }}.from_trusted_json(result.body)
    response_model.destroy
  end

  it "show" do
    model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
    model.persisted?.should be_true
    id = model.id.as(String)
    result = curl(
      method: "GET",
      path: base + id,
      headers: authorization_header,
    )

    result.status_code.should eq 200
    response_model = {{ klass.id }}.from_trusted_json(result.body)
    response_model.id.should eq id

    model.destroy
  end

  it "destroy" do
    model = PlaceOS::Model::Generator.{{ klass_name.id }}.save!
    model.persisted?.should be_true
    id = model.id.as(String)
    result = curl(
      method: "DELETE",
      path: base + id,
      headers: authorization_header,
    )

    result.status_code.should eq 200
    {{ klass.id }}.find(id).should be_nil
  end
end
