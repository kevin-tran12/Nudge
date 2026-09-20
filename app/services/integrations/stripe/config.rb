# STRIPE-SPECIFIC: removable provider integration; do not place domain logic here.

module Integrations
  module Stripe
    # Frozen snapshot of ENV read exactly once, at the Rails boundary, by
    # config/initializers/stripe.rb. Every other file depends on this object
    # (Rails.application.config.x.stripe) and never reads ENV directly.
    Config = Data.define(:secret_key, :webhook_secret, :mode) do
      # The only mode string that selects Stripe TEST-mode transport. Anything
      # else -- including any spelling of "live" -- is fixture. There is no
      # live-money mode: see Integrations::Stripe::ModePolicy.
      TEST_MODE = "test_mode"

      def credentials_present?
        secret_key.present?
      end

      # Stripe TEST-mode transport is a deliberate server configuration choice.
      # It is never derived from a request, and it is ignored unless credentials
      # are present, so a misconfigured deployment degrades to fixture instead of
      # failing open into a provider call it cannot authenticate. An unrecognized
      # mode string is fixture, never test mode.
      def test_mode?
        mode.to_s == TEST_MODE && credentials_present?
      end

      # Never expose secret values through inspect/logging.
      def inspect
        "#<#{self.class.name} credentials_present=#{credentials_present?} test_mode=#{test_mode?}>"
      end
      alias_method :to_s, :inspect

      def as_json(*)
        { "credentials_present" => credentials_present?, "test_mode" => test_mode? }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end
  end
end
