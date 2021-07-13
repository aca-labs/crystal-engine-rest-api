require "uri"

require "placeos-models/authority"
require "placeos-models/user"
require "placeos-models/user_jwt"

module PlaceOS::Api
  # Helper to grab user and authority from a request
  module Utils::CurrentUser
    # Parses, and validates JWT if present.
    # Throws Error::MissingBearer and JWT::Error.
    def authorize! : Model::UserJWT
      unless (token = @user_token).nil?
        return token
      end

      token = acquire_token

      # Request must have a bearer token
      raise Error::Unauthorized.new unless token

      begin
        @user_token = user_token = Model::UserJWT.decode(token)
      rescue e : JWT::Error
        Log.warn(exception: e) { {message: "bearer malformed", action: "authorize!"} }
        # Request bearer was malformed
        raise Error::Unauthorized.new "bearer malformed"
      end

      unless (authority = current_authority)
        Log.warn { {message: "authority not found", action: "authorize!", host: request.hostname} }
        raise Error::Unauthorized.new "authority not found"
      end

      # Token and authority domains must match
      token_domain_host = URI.parse(user_token.domain).host
      authority_domain_host = URI.parse(authority.domain.as(String)).host
      unless token_domain_host == authority_domain_host
        Log.warn { {message: "authority domain does not match token's", action: "authorize!", token_domain: user_token.domain, authority_domain: authority.domain} }
        raise Error::Unauthorized.new "authority domain does not match token's"
      end
      user_token
    rescue e
      # ensure that the user token is nil if this function ever errors.
      @user_token = nil
      raise e
    end

    def check_oauth_scope
      utoken = user_token
      unless utoken.scope.includes?("public")
        Log.warn { {message: "unknown scope #{utoken.scope}", action: "authorize!", host: request.hostname, id: utoken.id} }
        raise Error::Unauthorized.new "public scope required for access"
      end
    end

    # Obtains user referenced by user_token id
    getter current_user : Model::User { Model::User.find!(user_token.id) }

    # Obtains the authority for the request's host
    getter current_authority : Model::Authority? { Model::Authority.find_by_domain(request.hostname.as(String)) }

    # Getter for user_token
    getter user_token : Model::UserJWT { authorize! }

    # Read admin status from supplied request JWT
    def check_admin
      raise Error::Forbidden.new unless is_admin?
    end

    # Read support status from supplied request JWT
    def check_support
      raise Error::Forbidden.new unless is_support?
    end

    def is_admin?
      user_token.is_admin?
    end

    def is_support?
      token = user_token
      token.is_support? || token.is_admin?
    end

    # Pull JWT from...
    # - Authorization header
    # - "bearer_token" param
    protected def acquire_token : String?
      if (token = request.headers["Authorization"]?)
        token = token.lchop("Bearer ").rstrip
        token unless token.empty?
      elsif (token = params["bearer_token"]?)
        token.strip
      elsif (token = cookies["bearer_token"]?.try(&.value))
        token.strip
      end
    end
  end
end
