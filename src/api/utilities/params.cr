require "active-model"

module PlaceOS::Api
  abstract class Params < ActiveModel::Model
    # Helpers for model validations
    include ActiveModel::Validation

    # Checks that the model is valid
    # Responds with the validation errors
    def validate!
      raise Error::InvalidParams.new(self) unless self.valid?
      self
    end
  end
end
