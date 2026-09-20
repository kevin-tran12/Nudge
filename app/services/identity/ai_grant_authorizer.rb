require "digest"

module Identity
  class AiGrantAuthorizer
    Result = Data.define(:grant) do
      include Identity::NonSerializable

      def inspect
        "#<#{self.class.name} authorized=true>"
      end

      def as_json(*)
        { "authorized" => true }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end

    MAX_TOKEN_BYTES = 512

    def initialize(clock: -> { Time.current })
      @clock = clock
    end

    def call(shopping_session:, bearer_token:)
      validate_input!(shopping_session, bearer_token)
      outcome = shopping_session.with_lock do
        context = CurrentContext.new(clock: @clock).call(shopping_session:)
        now = @clock.call
        grant = context.current_shopping_session.ai_access_grants.find_by(
          grant_token_digest: Digest::SHA256.digest(bearer_token)
        )
        next :unauthorized_grant unless grant
        next :grant_inactive unless grant.status == "active"

        unless grant.active_at?(now)
          grant.update!(status: "expired")
          next :grant_inactive
        end

        Result.new(grant:).freeze
      end
      fail!(outcome) if outcome.is_a?(Symbol)
      outcome
    rescue Error => error
      raise Error.new(error.code), cause: nil
    rescue ActiveRecord::ActiveRecordError, TypeError
      fail!(:unauthorized_grant)
    rescue StandardError
      fail!(:conflict)
    end

    private
      def validate_input!(session, token)
        fail!(:invalid_input) unless session.is_a?(ShoppingSession)
        fail!(:unauthorized_grant) unless token.is_a?(String) && token.bytesize.between?(1, MAX_TOKEN_BYTES)
      end

      def fail!(code)
        raise Error.new(code), cause: nil
      end
  end
end
