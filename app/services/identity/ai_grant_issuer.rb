require "digest"
require "securerandom"

module Identity
  class AiGrantIssuer
    Result = Data.define(:grant, :bearer_token) do
      include Identity::NonSerializable

      def inspect
        "#<#{self.class.name} status=issued>"
      end

      def as_json(*)
        { "status" => "issued", "expires_at" => grant.expires_at.iso8601 }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end

    GRANT_LIFETIME = 60.minutes
    MAX_TEXT_BYTES = 255
    MIN_TOKEN_BYTES = 32
    MAX_TOKEN_BYTES = 512

    def initialize(clock: -> { Time.current }, token_generator: -> { SecureRandom.urlsafe_base64(32) })
      @clock = clock
      @token_generator = token_generator
    end

    def call(shopping_session:, disclosure_policy_version:, turnstile_verification:,
      expected_action:, expected_hostname:)
      validate_input!(shopping_session, disclosure_policy_version, turnstile_verification,
        expected_action, expected_hostname)

      shopping_session.with_lock do
        context = CurrentContext.new(clock: @clock).call(shopping_session:)
        session = context.current_shopping_session
        now = @clock.call
        consent = current_consent(session, disclosure_policy_version)
        fail!(:consent_required) unless consent

        verification = turnstile_verification.reload
        validate_verification!(verification, session, now, expected_action, expected_hostname)
        fail!(:verification_replayed) if AiAccessGrant.exists?(turnstile_verification_id: verification.id)

        active = session.ai_access_grants.find_by(status: "active")
        if active&.active_at?(now)
          fail!(:active_grant_exists)
        elsif active
          active.update!(status: "expired")
        end

        token = @token_generator.call
        fail!(:conflict) unless token.is_a?(String) && token.bytesize.between?(MIN_TOKEN_BYTES, MAX_TOKEN_BYTES)
        grant = session.ai_access_grants.create!(
          disclosure_consent_record: consent,
          turnstile_verification: verification,
          grant_token_digest: Digest::SHA256.digest(token),
          status: "active",
          issued_at: now,
          expires_at: now + GRANT_LIFETIME
        )
        Result.new(grant:, bearer_token: token.dup.freeze).freeze
      end
    rescue Error => error
      raise Error.new(error.code), cause: nil
    rescue ActiveRecord::RecordNotUnique
      raise Error.new(classify_unique_conflict(shopping_session, turnstile_verification)), cause: nil
    rescue StandardError
      fail!(:conflict)
    end

    private
      def validate_input!(session, policy_version, verification, action, hostname)
        fail!(:invalid_input) unless session.is_a?(ShoppingSession)
        fail!(:invalid_input) unless verification.is_a?(TurnstileVerification)
        [ policy_version, action, hostname ].each do |value|
          fail!(:invalid_input) unless value.is_a?(String) && value.bytesize.between?(1, MAX_TEXT_BYTES) &&
            !value.match?(/[\u0000-\u001f\u007f]/)
        end
      end

      def current_consent(session, policy_version)
        session.consent_records.current.find_by(
          consent_kind: "ai_provider_disclosure",
          policy_version:,
          decision: "accepted"
        )
      end

      def validate_verification!(verification, session, now, action, hostname)
        fail!(:verification_mismatch) unless verification.shopping_session_id == session.id
        fail!(:verification_failed) unless verification.success
        fail!(:verification_mismatch) unless verification.expected_action == action &&
          verification.validated_hostname == hostname
        fail!(:verification_expired) unless verification.fresh_at?(now)
      end

      def classify_unique_conflict(session, verification)
        return :verification_replayed if AiAccessGrant.exists?(turnstile_verification_id: verification.id)
        return :active_grant_exists if AiAccessGrant.exists?(shopping_session_id: session.id, status: "active")

        :conflict
      rescue ActiveRecord::ActiveRecordError
        :conflict
      end

      def fail!(code)
        raise Error.new(code), cause: nil
      end
  end
end
