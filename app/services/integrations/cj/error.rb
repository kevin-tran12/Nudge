module Integrations
  module Cj
    class Error < StandardError
      STRATEGIES = {
        invalid_input: :never, unsupported_mode: :never, fixture_miss: :never,
        malformed_response: :never, unsafe_url: :never, provider_rejected: :never,
        not_found: :never, authentication_failed: :pause, quota_exhausted: :pause,
        throttled: :backoff, unavailable: :backoff
      }.freeze

      attr_reader :code, :retry_strategy

      def initialize(code)
        @code = code
        @retry_strategy = STRATEGIES.fetch(code)
        # Never include provider messages, bodies, URLs or caller input.
        super("CJ adapter: #{code}")
      end

      def retryable?
        retry_strategy == :backoff
      end
    end
  end
end
