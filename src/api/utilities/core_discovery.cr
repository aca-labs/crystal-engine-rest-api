require "hound-dog"

module PlaceOS::Api
  class Discovery::Core < HoundDog::Discovery
    class_getter instance : Discovery::Core do
      new(service: CORE_NAMESPACE)
    end

    def initialize(**args)
      super **args

      @on_change = ->on_change(Array(HoundDog::Service::Node))
    end

    getter callbacks = [] of Array(HoundDog::Service::Node) ->

    def on_change(changes : Array(HoundDog::Service::Node))
      callbacks.each &.call changes
    end
  end
end
