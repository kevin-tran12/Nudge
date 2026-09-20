# STRIPE-SPECIFIC: removable provider integration; do not place domain logic here.

module Integrations
  module Stripe
    class Error < StandardError
      CODES = %i[
        invalid_input unsupported_mode missing_credentials authentication_failed
        provider_rejected malformed_response unavailable conflict not_found
      ].freeze

      attr_reader :code

      def initialize(code)
        raise ArgumentError, "unknown stripe error code" unless CODES.include?(code)

        @code = code
        @safe_message = "Stripe adapter: #{code}"
        # Never include provider messages, bodies, URLs, headers, or caller input.
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
end
