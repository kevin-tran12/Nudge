# STRIPE-SPECIFIC: removable provider integration; do not place domain logic here.

module Integrations
  module Stripe
    # Evaluates server configuration only; never construct from request parameters.
    #
    # There is no "live" mode: Stripe live-money authorization is an OPEN canonical
    # decision (capture/refund/cancellation policy is undecided), so this adapter is
    # permitted to reach only Stripe's TEST-mode API, never real money. The mode is
    # named :test_mode, not :live, to make that boundary explicit at every call site.
    #
    # TEST_MODE_CAPABILITY is an explicit server opt-in, not a credential or proof of
    # user authorization. No policy result enables a provider transport by itself: it
    # only decides which mode the Adapter is permitted to run in for this deployment.
    class ModePolicy
      TEST_MODE_CAPABILITY = Object.new.freeze
      MODES = [ :fixture, :test_mode ].freeze
      DEPLOYMENTS = [ :test, :development, :staging, :production ].freeze

      attr_reader :mode

      def initialize(deployment:, mode: :fixture, capability: nil)
        @mode = normalize(mode, MODES)
        deployment = normalize(deployment, DEPLOYMENTS)
        allowed = case deployment
        when :test
          @mode == :fixture
        when :development, :staging
          @mode == :fixture || (@mode == :test_mode && TEST_MODE_CAPABILITY.equal?(capability))
        when :production
          @mode == :test_mode && TEST_MODE_CAPABILITY.equal?(capability)
        end
        raise Error.new(:unsupported_mode), cause: nil unless allowed

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
