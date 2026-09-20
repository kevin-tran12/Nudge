module Identity
  class BrowserSessionCookie
    include Identity::NonSerializable

    COOKIE_NAME = :nudge_shopping_session
    SIGNING_SALT = "nudge.shopping-session-cookie.v1"
    MAX_COOKIE_BYTES = 4_096
    STRING_SERIALIZER = Module.new do
      module_function

      def dump(value)
        raise TypeError unless value.is_a?(String)

        value
      end

      def load(value)
        value
      end
    end

    def initialize(cookie_jar:, clock: -> { Time.current }, secure: !Rails.env.local?, environment: Rails.env,
      current_context: Identity::CurrentContext.new, verifier: nil)
      @cookie_jar = cookie_jar
      @clock = clock
      @secure = environment.to_s == "production" || secure == true
      @current_context = current_context
      @verifier = verifier
    end

    def resolve
      raw_cookie = @cookie_jar[COOKIE_NAME]
      return if raw_cookie.nil?
      return clear_anonymous unless raw_cookie.is_a?(String) && raw_cookie.bytesize <= MAX_COOKIE_BYTES

      public_id = verifier.verified(raw_cookie)
      return clear_anonymous unless valid_public_id?(public_id)

      shopping_session = ShoppingSession.find_by(public_id:)
      return clear_anonymous unless shopping_session

      @current_context.call(shopping_session:, now: @clock.call)
    rescue Identity::Error, ActiveRecord::ActiveRecordError, ActionDispatch::Cookies::CookieOverflow,
      ArgumentError, TypeError
      clear_anonymous
    rescue StandardError
      clear_anonymous
    end

    def write(shopping_session:)
      fail_invalid! unless shopping_session.is_a?(ShoppingSession) && shopping_session.persisted?

      context = @current_context.call(shopping_session:, now: @clock.call)
      session = context.current_shopping_session
      fail_invalid! unless valid_public_id?(session.public_id)

      @cookie_jar[COOKIE_NAME] = {
        value: verifier.generate(session.public_id),
        expires: session.expires_at,
        httponly: true,
        secure: @secure,
        same_site: :lax,
        path: "/"
      }
      true
    rescue Identity::Error => error
      safe_clear
      raise Identity::Error.new(error.code), cause: nil
    rescue ActiveRecord::ActiveRecordError, ActionDispatch::Cookies::CookieOverflow, ArgumentError, TypeError
      safe_clear
      fail_invalid!
    rescue StandardError
      safe_clear
      raise Identity::Error.new(:conflict), cause: nil
    end

    def clear
      safe_clear
      true
    end

    def inspect
      "#<#{self.class.name}>"
    end

    def as_json(*)
      { "configured" => true }
    end

    def to_json(...)
      as_json.to_json(...)
    end

    private

    def valid_public_id?(value)
      value.is_a?(String) && value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
    end

    def verifier
      @verifier ||= begin
        secret = Rails.application.key_generator.generate_key(SIGNING_SALT, 64)
        ActiveSupport::MessageVerifier.new(
          secret,
          digest: "SHA256",
          serializer: STRING_SERIALIZER,
          url_safe: true
        )
      end
    end

    def clear_anonymous
      safe_clear
      nil
    end

    def safe_clear
      @cookie_jar.delete(COOKIE_NAME, path: "/", secure: @secure, same_site: :lax)
    rescue StandardError
      nil
    end

    def fail_invalid!
      raise Identity::Error.new(:invalid_input), cause: nil
    end
  end
end
