module Integrations
  module Prodigi
    # Frozen snapshot of ENV read exactly once, at the Rails boundary, by
    # config/initializers/prodigi.rb. Every other file depends on this object
    # (Rails.application.config.x.prodigi) and never reads ENV directly.
    Config = Data.define(:api_key, :mode) do
      # The only mode string that selects Prodigi sandbox transport. Anything
      # else -- including any spelling of "live" -- is fixture. There is no
      # live-fulfillment mode: see Integrations::Prodigi::ModePolicy.
      SANDBOX_MODE = "sandbox"

      def credentials_present?
        api_key.present?
      end

      # Prodigi sandbox transport is a deliberate server configuration choice.
      # It is never derived from a request, and it is ignored unless
      # credentials are present, so a misconfigured deployment degrades to
      # fixture instead of failing open into a provider call it cannot
      # authenticate. An unrecognized mode string is fixture, never sandbox.
      def sandbox?
        mode.to_s == SANDBOX_MODE && credentials_present?
      end

      # Never expose the api_key through inspect/logging.
      def inspect
        "#<#{self.class.name} credentials_present=#{credentials_present?} sandbox=#{sandbox?}>"
      end
      alias_method :to_s, :inspect

      def as_json(*)
        { "credentials_present" => credentials_present?, "sandbox" => sandbox? }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end
  end
end
