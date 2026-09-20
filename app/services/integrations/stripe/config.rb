# STRIPE-SPECIFIC: removable provider integration; do not place domain logic here.

module Integrations
  module Stripe
    # Frozen snapshot of ENV read exactly once, at the Rails boundary, by
    # config/initializers/stripe.rb. Every other file depends on this object
    # (Rails.application.config.x.stripe) and never reads ENV directly.
    Config = Data.define(:secret_key, :webhook_secret) do
      def credentials_present?
        secret_key.present?
      end

      # Never expose secret values through inspect/logging.
      def inspect
        "#<#{self.class.name} credentials_present=#{credentials_present?}>"
      end
      alias_method :to_s, :inspect

      def as_json(*)
        { "credentials_present" => credentials_present? }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end
  end
end
