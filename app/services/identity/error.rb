module Identity
  class Error < StandardError
    include Identity::NonSerializable

    CODES = %i[
      invalid_input session_inactive session_expired user_inactive consent_required
      verification_failed verification_expired verification_mismatch verification_replayed
      active_grant_exists unauthorized_grant grant_inactive conflict
    ].freeze

    attr_reader :code

    def initialize(code)
      raise ArgumentError, "unknown identity error code" unless CODES.include?(code)

      @code = code
      super("Identity: #{code}")
    end

    def inspect
      "#<#{self.class.name} code=#{code.inspect}>"
    end

    def as_json(*)
      { "code" => code.to_s }
    end

    def to_json(...)
      as_json.to_json(...)
    end
  end
end
