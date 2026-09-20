# ELEVENLABS-SPECIFIC: removable provider integration; do not place domain logic here.

module Integrations
  module ElevenLabs
    class Error < StandardError
      CODES = %i[
        invalid_input unsupported_mode missing_credentials authentication_failed
        provider_rejected malformed_response unavailable conflict
      ].freeze

      attr_reader :code

      def initialize(code)
        raise ArgumentError, "unknown eleven labs error code" unless CODES.include?(code)

        @code = code
        @safe_message = "ElevenLabs adapter: #{code}"
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
