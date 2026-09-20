# ELEVENLABS-SPECIFIC: removable provider integration; do not place domain logic here.

module Integrations
  module ElevenLabs
    # Frozen snapshot of ENV read exactly once, at the Rails boundary, by
    # config/initializers/eleven_labs.rb. Every other file depends on this object
    # (Rails.application.config.x.eleven_labs) and never reads ENV directly.
    Config = Data.define(:api_key, :agent_id, :tool_secret, :webhook_secret, :mode) do
      def credentials_present?
        api_key.present? && agent_id.present?
      end

      # Live transport is a deliberate server configuration choice. It is never
      # derived from a request, and it is ignored unless credentials are present,
      # so a misconfigured deployment degrades to fixture instead of failing open
      # into a provider call it cannot authenticate.
      def live?
        mode.to_s == "live" && credentials_present?
      end

      # Never expose secret values through inspect/logging.
      def inspect
        "#<#{self.class.name} credentials_present=#{credentials_present?} live=#{live?}>"
      end
      alias_method :to_s, :inspect

      def as_json(*)
        { "credentials_present" => credentials_present?, "live" => live? }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end
  end
end
