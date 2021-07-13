module PlaceOS::Api
  module Utils::CoreHelper
    # Determine a user's Driver execution privilege
    def driver_clearance(user : Model::User | Model::UserJWT)
      case user
      when .is_admin?   then Driver::Proxy::RemoteDriver::Clearance::Admin
      when .is_support? then Driver::Proxy::RemoteDriver::Clearance::Support
      else                   Driver::Proxy::RemoteDriver::Clearance::User
      end
    end
  end
end
