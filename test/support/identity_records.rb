require "digest"

module TestSupport
  module IdentityRecords
    REFERENCE_TIME = Time.utc(2026, 9, 20, 12, 0, 0)

    def clear_identity_records
      AiAccessGrant.delete_all if defined?(AiAccessGrant)
      TurnstileVerification.delete_all if defined?(TurnstileVerification)
      ConsentRecord.delete_all if defined?(ConsentRecord)
      ShoppingSession.delete_all if defined?(ShoppingSession)
      User.delete_all if defined?(User)
    end

    def create_user(status: "active")
      User.create!(status:)
    end

    def create_shopping_session(user: nil, status: "active", expires_at: REFERENCE_TIME + 2.hours)
      ShoppingSession.create!(
        user:,
        status:,
        started_at: REFERENCE_TIME - 1.hour,
        last_activity_at: REFERENCE_TIME - 1.minute,
        expires_at:
      )
    end

    def create_consent(session:, policy_version: "disclosure-v1", decision: "accepted", withdrawn_at: nil)
      ConsentRecord.create!(
        shopping_session: session,
        user: session.user,
        consent_kind: "ai_provider_disclosure",
        policy_version:,
        decision:,
        scope_json: { "provider" => "elevenlabs" },
        scope_schema_version: 1,
        recorded_at: REFERENCE_TIME - 2.minutes,
        withdrawn_at:,
        correlation_id: SecureRandom.uuid
      )
    end

    def create_verification(session:, success: true, action: "ai_grant", hostname: "shop.example.test",
      challenge_timestamp: REFERENCE_TIME - 2.minutes, validated_at: REFERENCE_TIME - 1.minute,
      expires_at: REFERENCE_TIME + 4.minutes, token: SecureRandom.hex(16))
      TurnstileVerification.create!(
        shopping_session: session,
        token_digest: Digest::SHA256.digest(token),
        expected_action: action,
        validated_hostname: hostname,
        success:,
        failure_code: ("challenge_failed" unless success),
        challenge_timestamp:,
        validated_at:,
        expires_at:,
        purge_after: REFERENCE_TIME + 30.days
      )
    end
  end
end
