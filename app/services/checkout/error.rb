module Checkout
  class Error < StandardError
    CODES = %i[
      invalid_input session_required cart_not_found cart_empty unknown_price
      currency_mismatch not_found forbidden conflict provider_unavailable
    ].freeze

    attr_reader :code

    def initialize(code)
      raise ArgumentError, "unknown checkout error code" unless CODES.include?(code)

      @code = code
      @safe_message = "Checkout: #{code}"
      super(@safe_message)
    end

    def inspect
      "#<#{self.class.name} code=#{code.inspect}>"
    end

    def to_s
      @safe_message
    end

    def as_json(*)
      { "code" => code.to_s }
    end

    def to_json(...)
      as_json.to_json(...)
    end
  end
end
