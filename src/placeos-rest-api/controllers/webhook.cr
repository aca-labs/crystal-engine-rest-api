require "./application"

module PlaceOS::Api
  class Webhook < Application
    base "/api/engine/v2/webhook/"

    skip_action :authorize!, except: [:show]
    skip_action :set_user_id, except: [:show]
    before_action :find_hook

    @trigger_instance : Model::TriggerInstance?
    @trigger : Model::Trigger?

    def show
      render json: current_trigger
    end

    alias RemoteDriver = ::PlaceOS::Driver::Proxy::RemoteDriver

    # Triggers the webhook
    def notify(method_type : String) # ameba:disable Metrics/CyclomaticComplexity
      trigger_instance = current_trigger_instance
      trigger = current_trigger

      # Notify the trigger service
      trigger_uri = TRIGGERS_URI.dup
      trigger_uri.path = "/api/triggers/v2/webhook?id=#{trigger_instance.id}&secret=#{trigger_instance.webhook_secret}"
      trigger_response = HTTP::Client.post(
        trigger_uri,
        headers: HTTP::Headers{"X-Request-ID" => request_id}
      )

      # Execute the requested method
      if params["exec"]? == "true"
        exec_params = ExecParams.new(params).validate!

        if trigger_instance.exec_enabled
          driver = RemoteDriver.new(
            trigger_instance.control_system_id.as(String),
            exec_params.mod.as(String),
            exec_params.index.as(Int32)
          )

          body_data = request.body.try(&.gets_to_end) || ""
          header_data = request.headers.try(&.to_h) || Hash(String, Array(String)).new

          args = {method_type, header_data, body_data}

          exec_response = String.from_json(driver.exec(
            security: RemoteDriver::Clearance::Support,
            function: exec_params.method.as(String),
            args: args,
            request_id: request_id
          ))

          # We expect that the method being called is aware of its role as a trigger
          if !exec_response.empty?
            Log.debug { "webhook exec response: #{exec_response}" }
            begin
              response_code, response_headers, response_body = Tuple(Int32, Hash(String, String)?, String?).from_json(exec_response)

              if response_headers
                # Forward response headers from the remote driver
                response_headers.each { |key, value| @context.response.headers[key] = value }
              end

              # These calls to render will return
              if response_body && !response_body.empty?
                render response_code, text: response_body
              else
                head response_code
              end
            rescue error
              Log.info(exception: error) { "trigger function response not valid #{trigger_instance.control_system_id} - #{exec_params.friendly}" }
            end
          end
        else
          Log.warn { "attempt to execute function on trigger #{trigger_instance.id} - #{exec_params.friendly}" }
        end
      end

      head :accepted if trigger_response.success?
      head :not_found
    end

    {% for http_method in ActionController::Router::HTTP_METHODS.reject { |verb| verb == "head" } %}
      {{http_method.id}} "/:id/notify" do
        return notify({{http_method.id.stringify.upcase}}) if current_trigger.supported_method? {{http_method.id.stringify.upcase}}
        Log.warn { "attempt to notify trigger #{current_trigger_instance.id} with unsupported method #{{{http_method.id.stringify}}}" }
        head :not_found
      end
    {% end %}

    class WebhookParams < Params
      attribute id : String
      attribute secret : String

      validates :id, presence: true
      validates :secret, presence: true
    end

    class ExecParams < WebhookParams
      attribute mod : String
      attribute index : Int32 = 1
      attribute method : String

      def friendly
        "#{@mod}_#{@index.as(Int32)}.#{method}"
      end

      validates :mod, presence: true
      validates :method, presence: true
    end

    def find_hook
      args = WebhookParams.new(params).validate!

      sys_trig_id = args.id.as(String)
      Log.context.set(trigger_instance_id: sys_trig_id)

      # Find will raise a 404 (not found) if there is an error
      trigger_instance = Model::TriggerInstance.find!(sys_trig_id)
      trigger = trigger_instance.trigger

      # Determine the validity of loaded TriggerInstance
      unless trigger_instance.enabled &&
             trigger_instance.webhook_secret == args.secret &&
             trigger
        head :not_found
      end

      Log.context.set(trigger_id: trigger.id)

      @trigger_instance = trigger_instance
      @trigger = trigger
    end

    def current_trigger
      return @trigger.as(Model::Trigger) if @trigger
      find_hook
      current_trigger
    end

    def current_trigger_instance
      return @trigger_instance.as(Model::TriggerInstance) if @trigger_instance
      find_hook
      current_trigger_instance
    end
  end
end
