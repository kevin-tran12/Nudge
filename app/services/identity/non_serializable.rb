module Identity
  module NonSerializable
    SERIALIZATION_ERROR = "Identity result serialization is disabled".freeze

    def encode_with(*)
      raise TypeError, SERIALIZATION_ERROR
    end

    def marshal_dump
      raise TypeError, SERIALIZATION_ERROR
    end
  end
end
