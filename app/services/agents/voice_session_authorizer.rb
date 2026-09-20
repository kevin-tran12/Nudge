require "digest"
require "securerandom"

module Agents
  # Demo-mode voice bootstrap + just-in-time ElevenLabs authorization (VOICE-01).
  #
  # DEMO MODE ONLY. This authorizer creates the guest shopping session, disclosure
  # consent, and Turnstile verification records that would normally already exist
  # from a real disclosure UI and a real Cloudflare Turnstile challenge (AUTH-002 /
  # AUTH-001). Those records are consumed as-is by the MERGED identity grant
  # machinery (Identity::AiGrantIssuer); this class never re-implements grant
  # issuance itself. It exists only to unblock a hackathon demo and is hard-gated
  # to non-production deployments: see `refuse_outside_demo_deployment!`. The demo
  # disclosure policy version below is a placeholder, not legal or privacy copy —
  # the real disclosure text and policy version remain an open owner decision.
  class VoiceSessionAuthorizer
    class Error < StandardError
      CODES = %i[
        invalid_input demo_mode_unavailable session_bootstrap_failed
        consent_required verification_failed grant_conflict provider_unavailable
      ].freeze

      attr_reader :code

      def initialize(code)
        raise ArgumentError, "unknown voice session authorizer error code" unless CODES.include?(code)

        @code = code
        super("VoiceSessionAuthorizer: #{code}")
      end

      def as_json(*)
        { "code" => code.to_s }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end

    # grant_token is the raw AI-grant bearer the browser must present to the tool
    # endpoint. It is returned exactly once, kept out of inspect, and held only in
    # memory by the client. The conversation token authenticates the provider
    # widget and is not accepted as an application credential.
    Result = Data.define(:conversation_token, :grant_token, :agent_id, :expires_at) do
      def inspect
        "#<#{self.class.name} agent_id=#{agent_id.inspect} expires_at=#{expires_at.iso8601}>"
      end

      def as_json(*)
        {
          "conversation_token" => conversation_token,
          "grant_token" => grant_token,
          "agent_id" => agent_id,
          "expires_at" => expires_at.iso8601
        }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end

    # AUTH-001 default lifetime for a demo-bootstrapped guest session. Change only here.
    DEMO_SESSION_LIFETIME = 2.hours
    # Placeholder policy version for the demo path. Not legal/privacy copy.
    DEMO_DISCLOSURE_POLICY_VERSION = "demo-disclosure-v0"
    DEMO_EXPECTED_ACTION = "voice_session_demo_bootstrap"
    DEMO_VERIFICATION_FRESHNESS = 4.minutes
    NON_PRODUCTION_DEPLOYMENTS = %w[test development staging].freeze
    MAX_HOSTNAME_BYTES = 255

    def initialize(clock: -> { Time.current }, verification_token_generator: -> { SecureRandom.hex(24) },
      issuer: Identity::AiGrantIssuer.new, adapter: Integrations::ElevenLabs::Adapter.build, deployment: Rails.env)
      @clock = clock
      @verification_token_generator = verification_token_generator
      @issuer = issuer
      @adapter = adapter
      @deployment = deployment.to_s
    end

    # cookie: an Identity::BrowserSessionCookie bound to the current request's cookie jar.
    # context: the already server-resolved Identity::CurrentContext::Result, or nil when
    #          no valid session cookie is present. Callers must never pass a
    #          client-selected identifier here — only what the trusted cookie resolved to.
    # expected_hostname: request.host, read server-side by the controller.
    def call(cookie:, context:, expected_hostname:)
      refuse_outside_demo_deployment!
      validate_input!(cookie, context, expected_hostname)

      shopping_session = context&.current_shopping_session || bootstrap_shopping_session!(cookie)
      consent = ensure_demo_consent!(shopping_session)
      verification = ensure_demo_verification!(shopping_session, expected_hostname)

      revoke_active_grants!(shopping_session)

      grant_result = @issuer.call(
        shopping_session: shopping_session,
        disclosure_policy_version: consent.policy_version,
        turnstile_verification: verification,
        expected_action: DEMO_EXPECTED_ACTION,
        expected_hostname: expected_hostname
      )

      authorization = @adapter.conversation_authorization
      Result.new(
        conversation_token: authorization.conversation_token,
        grant_token: grant_result.bearer_token,
        agent_id: authorization.agent_id,
        expires_at: [ grant_result.grant.expires_at, authorization.expires_at ].min
      ).freeze
    rescue Identity::Error => error
      raise translate_identity_error(error), cause: nil
    rescue Integrations::ElevenLabs::Error
      raise Error.new(:provider_unavailable), cause: nil
    end

    private

    # A grant's raw bearer token is returned exactly once and only its digest is
    # stored, so an interrupted attempt -- a dismissed microphone prompt, a reload,
    # a dropped connection -- leaves an active grant whose token nobody holds. The
    # issuer then correctly refuses to mint a second one, and the visitor is locked
    # out for the full grant lifetime with no way to recover.
    #
    # Pressing the button again is an explicit re-authorization, so retire the
    # unusable grant first. The issuer's one-active-grant invariant is preserved:
    # the old grant is expired before a new one exists, under the session lock.
    def revoke_active_grants!(shopping_session)
      shopping_session.with_lock do
        shopping_session.ai_access_grants.where(status: "active").find_each do |grant|
          grant.update!(status: "expired")
        end
      end
    end

    def refuse_outside_demo_deployment!
      raise Error.new(:demo_mode_unavailable), cause: nil unless NON_PRODUCTION_DEPLOYMENTS.include?(@deployment)
    end

    def validate_input!(cookie, context, expected_hostname)
      raise Error.new(:invalid_input), cause: nil unless cookie.is_a?(Identity::BrowserSessionCookie)
      raise Error.new(:invalid_input), cause: nil unless context.nil? || context.instance_of?(Identity::CurrentContext::Result)
      unless expected_hostname.is_a?(String) && expected_hostname.bytesize.between?(1, MAX_HOSTNAME_BYTES) &&
          !expected_hostname.match?(/[\u0000-\u001f\u007f]/)
        raise Error.new(:invalid_input), cause: nil
      end
    end

    def bootstrap_shopping_session!(cookie)
      now = @clock.call
      session = ShoppingSession.create!(
        user: nil,
        status: "active",
        started_at: now,
        last_activity_at: now,
        expires_at: now + DEMO_SESSION_LIFETIME
      )
      cookie.write(shopping_session: session)
      session
    rescue ActiveRecord::ActiveRecordError, Identity::Error
      raise Error.new(:session_bootstrap_failed), cause: nil
    end

    def ensure_demo_consent!(shopping_session)
      Identity::ConsentRecorder.new(clock: @clock).call(
        shopping_session: shopping_session,
        policy_version: DEMO_DISCLOSURE_POLICY_VERSION,
        decision: "accepted",
        scope_json: { "provider" => "elevenlabs", "mode" => "demo" },
        scope_schema_version: 1
      ).record
    rescue Identity::Error
      raise Error.new(:consent_required), cause: nil
    end

    # No real Cloudflare Turnstile challenge runs on the demo path: this manufactures
    # the verification record the MERGED grant issuer requires, scoped to this one
    # request only and consumed by exactly one grant (single-use, per the issuer).
    def ensure_demo_verification!(shopping_session, expected_hostname)
      now = @clock.call
      shopping_session.turnstile_verifications.create!(
        token_digest: Digest::SHA256.digest(@verification_token_generator.call),
        expected_action: DEMO_EXPECTED_ACTION,
        validated_hostname: expected_hostname,
        success: true,
        challenge_timestamp: now,
        validated_at: now,
        expires_at: now + DEMO_VERIFICATION_FRESHNESS,
        purge_after: now + 30.days
      )
    rescue ActiveRecord::ActiveRecordError
      raise Error.new(:verification_failed), cause: nil
    end

    def translate_identity_error(error)
      case error.code
      when :consent_required
        Error.new(:consent_required)
      when :verification_failed, :verification_expired, :verification_mismatch, :verification_replayed
        Error.new(:verification_failed)
      when :active_grant_exists
        Error.new(:grant_conflict)
      else
        Error.new(:session_bootstrap_failed)
      end
    end
  end
end
