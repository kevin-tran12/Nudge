module Integrations
  module Cj
    # Frozen snapshot of ENV read exactly once, at the Rails boundary, by
    # config/initializers/cj.rb. Every other file depends on this object
    # (Rails.application.config.x.cj) and never reads ENV directly.
    #
    # This holds only the long-lived CJ credential used to obtain short-lived
    # access tokens through Integrations::Cj::Authentication. It never carries
    # a mode: mode selection always goes through ModePolicy's explicit
    # capability sentinels, never through this object or a bare ENV flag.
    Config = Data.define(:api_key) do
      def credentials_present?
        api_key.present?
      end

      # Never expose the credential through inspect/logging/serialization.
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
