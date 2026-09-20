# ELEVENLABS-SPECIFIC: removable provider integration; do not place domain logic here.

require "net/http"
require "json"
require "uri"
require "digest"

module Integrations
  module ElevenLabs
    # One narrow operation: obtain a short-lived conversation authorization token
    # for the configured agent. Fixture mode is deterministic and makes zero
    # network calls; live mode calls the ElevenLabs REST API. No raw provider
    # object escapes this class and the API key is never logged, inspected, or
    # serialized (it lives only in the local `api_key` variable of one method).
    class Adapter
      API_HOST = "api.elevenlabs.io"
      TOKEN_PATH = "/v1/convai/conversation/token"
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 5
      TOKEN_TTL = 15.minutes
      AGENT_ID_PATTERN = /\A[A-Za-z0-9_-]{1,128}\z/

      Result = Data.define(:conversation_token, :agent_id, :expires_at) do
        def inspect
          "#<#{self.class.name} agent_id=#{agent_id.inspect} expires_at=#{expires_at.iso8601}>"
        end

        def as_json(*)
          { "conversation_token" => conversation_token, "agent_id" => agent_id, "expires_at" => expires_at.iso8601 }
        end

        def to_json(...)
          as_json.to_json(...)
        end
      end

      attr_reader :mode

      def initialize(mode_policy: ModePolicy.new(deployment: Rails.env), config: Rails.application.config.x.eleven_labs,
        clock: -> { Time.current }, http_client: nil)
        raise Error.new(:invalid_input), cause: nil unless mode_policy.instance_of?(ModePolicy)
        raise Error.new(:invalid_input), cause: nil unless config.instance_of?(Config)

        @mode = mode_policy.mode
        @config = config
        @clock = clock
        @http_client = http_client || method(:perform_request)
      end

      def conversation_authorization
        agent_id = resolve_agent_id
        case @mode
        when :fixture
          fixture_authorization(agent_id)
        when :live
          live_authorization(agent_id)
        else
          raise Error.new(:unsupported_mode), cause: nil
        end
      end

      private

      def resolve_agent_id
        agent_id = @config.agent_id
        raise Error.new(:missing_credentials), cause: nil unless agent_id.is_a?(String) && agent_id.match?(AGENT_ID_PATTERN)

        agent_id.dup
      end

      def fixture_authorization(agent_id)
        now = @clock.call
        token = "fixture-conversation-token-#{Digest::SHA256.hexdigest(agent_id)[0, 32]}"
        Result.new(conversation_token: token.freeze, agent_id: agent_id.freeze, expires_at: now + TOKEN_TTL).freeze
      end

      def live_authorization(agent_id)
        api_key = @config.api_key
        raise Error.new(:missing_credentials), cause: nil unless api_key.is_a?(String) && !api_key.empty?

        body = @http_client.call(agent_id: agent_id, api_key: api_key)
        token = body["token"]
        raise Error.new(:malformed_response), cause: nil unless token.is_a?(String) && token.bytesize.between?(1, 8_192)

        Result.new(conversation_token: token.dup.freeze, agent_id: agent_id.freeze, expires_at: @clock.call + TOKEN_TTL).freeze
      rescue Error
        raise
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end

      # Real network transport. Only reached in :live mode, which is unreachable
      # without an explicit LIVE_CAPABILITY sentinel from trusted server code.
      def perform_request(agent_id:, api_key:)
        uri = URI::HTTPS.build(host: API_HOST, path: TOKEN_PATH, query: URI.encode_www_form(agent_id: agent_id))
        request = Net::HTTP::Get.new(uri)
        request["xi-api-key"] = api_key
        request["Accept"] = "application/json"

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        when Net::HTTPUnauthorized, Net::HTTPForbidden
          raise Error.new(:authentication_failed), cause: nil
        when Net::HTTPTooManyRequests, Net::HTTPServerError
          raise Error.new(:unavailable), cause: nil
        else
          raise Error.new(:provider_rejected), cause: nil
        end
      rescue JSON::ParserError
        raise Error.new(:malformed_response), cause: nil
      rescue Error
        raise
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end
    end
  end
end
