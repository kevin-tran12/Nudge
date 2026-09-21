module Integrations
  module Prodigi
    class Error < StandardError
      CODES = %i[
        invalid_input unsupported_mode fixture_miss missing_credentials malformed_response
        unsafe_url authentication_failed throttled unavailable provider_rejected
        validation_failed not_found conflict
      ].freeze

      # create_order's no-auto-retry rule lives at the Adapter call site, not
      # here: this map only describes what is safe to retry at the transport
      # level (a throttled/unavailable response means the same thing
      # regardless of which operation produced it), never whether a specific
      # operation is safe to retry.
      STRATEGIES = CODES.each_with_object({}) do |code, memo|
        memo[code] = %i[throttled unavailable].include?(code) ? :backoff : :never
      end.freeze

      attr_reader :code, :retry_after, :retry_strategy

      def initialize(code, retry_after: nil)
        raise ArgumentError, "unknown prodigi error code" unless CODES.include?(code)

        @code = code
        @retry_after = retry_after
        @retry_strategy = STRATEGIES.fetch(code)
        @safe_message = "Prodigi adapter: #{code}"
        # Never include provider messages, bodies, URLs, headers, or caller input.
        super(@safe_message)
      end

      def retryable?
        retry_strategy == :backoff
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
