module Integrations
  module Cj
    # Evaluates server configuration only; never construct from request parameters.
    # These identity capabilities are explicit server opt-ins, not credentials or
    # proof of user authorization. No policy result enables a provider transport.
    class ModePolicy
      VERIFY_CAPABILITY = Object.new.freeze
      RECORD_CAPABILITY = Object.new.freeze
      LIVE_CAPABILITY = Object.new.freeze
      CEILINGS = { fixture: 0, verify: 500, record: 2_500, live: nil }.freeze
      DEPLOYMENTS = [ :test, :development, :staging, :production ].freeze

      attr_reader :mode, :ceiling

      def initialize(deployment:, mode: :fixture, capability: nil)
        @mode = normalize(mode, CEILINGS.keys)
        deployment = normalize(deployment, DEPLOYMENTS)
        allowed = case deployment
        when :test
          @mode == :fixture
        when :development, :staging
          @mode == :fixture || (@mode == :verify && VERIFY_CAPABILITY.equal?(capability)) ||
            (@mode == :record && RECORD_CAPABILITY.equal?(capability))
        when :production
          @mode == :live && LIVE_CAPABILITY.equal?(capability)
        end
        raise Error.new(:unsupported_mode), cause: nil unless allowed

        @ceiling = CEILINGS.fetch(@mode)
        freeze
      end

      private

      def normalize(value, allowed)
        normalized = allowed.find { |entry| entry == value || entry.to_s == value } if value.is_a?(String) || value.is_a?(Symbol)
        normalized || raise(Error.new(:unsupported_mode), cause: nil)
      end
    end
  end
end
