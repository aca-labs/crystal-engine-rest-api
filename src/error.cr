module Engine::API
  class Error < Exception
    getter :message

    def initialize(@message : String? = "")
      super(message)
    end

    class InvalidParams < Error
      getter params

      def initialize(@params : Params, message = "")
        super(message)
      end
    end
  end
end