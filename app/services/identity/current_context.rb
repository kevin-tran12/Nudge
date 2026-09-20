module Identity
  class CurrentContext
    Result = Data.define(:current_shopping_session, :current_user) do
      include Identity::NonSerializable

      def inspect
        "#<#{self.class.name} authenticated=#{!current_user.nil?}>"
      end

      def as_json(*)
        { "authenticated" => !current_user.nil? }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end

    def initialize(clock: -> { Time.current })
      @clock = clock
    end

    def call(shopping_session:, now: nil)
      fail!(:invalid_input) unless shopping_session.is_a?(ShoppingSession)

      session = shopping_session.reload
      now ||= @clock.call
      fail!(:invalid_input) unless now.respond_to?(:<)
      fail!(:session_inactive) unless session.status == "active"
      fail!(:session_inactive) unless session.started_at <= now
      fail!(:session_expired) unless now < session.expires_at
      fail!(:user_inactive) if session.user && session.user.status != "active"

      Result.new(current_shopping_session: session, current_user: session.user).freeze
    rescue Error => error
      raise Error.new(error.code), cause: nil
    rescue ActiveRecord::ActiveRecordError, TypeError
      fail!(:invalid_input)
    rescue StandardError
      fail!(:conflict)
    end

    private
      def fail!(code)
        raise Error.new(code), cause: nil
      end
  end
end
