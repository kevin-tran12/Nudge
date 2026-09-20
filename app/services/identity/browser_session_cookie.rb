module Identity
  class BrowserSessionCookie
    include Identity::NonSerializable

    COOKIE_NAME = :nudge_shopping_session
    SIGNING_SALT = "nudge.shopping-session-cookie.v1"
    PAYLOAD_PREFIX = "nudge.shopping_session.v1:"
    MAX_COOKIE_BYTES = 4_096
    MAX_PREVIOUS_KEY_GENERATORS = 3
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
      current_context: Identity::CurrentContext.new, key_generator: Rails.application.key_generator,
      previous_key_generators: [])
      fail_invalid! unless key_generator.respond_to?(:generate_key)
      fail_invalid! unless previous_key_generators.is_a?(Array)
      fail_invalid! if previous_key_generators.size > MAX_PREVIOUS_KEY_GENERATORS
      fail_invalid! unless previous_key_generators.all? { |generator| generator.respond_to?(:generate_key) }

      @cookie_jar = cookie_jar
      @clock = clock
      @secure = environment.to_s == "production" || secure == true
      @current_context = current_context
      @key_generator = key_generator
      @previous_key_generators = previous_key_generators.dup.freeze
    end

    def resolve
      raw_cookie = @cookie_jar[COOKIE_NAME]
      return if raw_cookie.nil?
      return clear_anonymous unless raw_cookie.is_a?(String) && raw_cookie.bytesize <= MAX_COOKIE_BYTES

      payload = read_verifiers.lazy.filter_map { |candidate| candidate.verified(raw_cookie) }.first
      public_id = parse_payload(payload)
      return clear_anonymous unless public_id

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
        value: current_verifier.generate("#{PAYLOAD_PREFIX}#{session.public_id}"),
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
      delete_cookie!
      true
    rescue StandardError
      raise Identity::Error.new(:conflict), cause: nil
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

    def parse_payload(payload)
      return unless payload.is_a?(String) && payload.start_with?(PAYLOAD_PREFIX)

      public_id = payload.delete_prefix(PAYLOAD_PREFIX)
      public_id if valid_public_id?(public_id)
    end

    # The locked Rails/JSON pair cannot reliably decode MessageVerifier purpose metadata.
    # Keep domain separation in both the KDF salt and an exact, versioned string prefix;
    # the string-only serializer also prevents unsafe object deserialization.
    def current_verifier
      @current_verifier ||= build_verifier(@key_generator)
    end

    def read_verifiers
      @read_verifiers ||= [
        current_verifier,
        *@previous_key_generators.map { |generator| build_verifier(generator) }
      ].freeze
    end

    def build_verifier(key_generator)
      secret = key_generator.generate_key(SIGNING_SALT, 64)
      ActiveSupport::MessageVerifier.new(
        secret,
        digest: "SHA256",
        serializer: STRING_SERIALIZER,
        url_safe: true
      )
    end

    def clear_anonymous
      safe_clear
      nil
    end

    def safe_clear
      delete_cookie!
    rescue StandardError
      nil
    end

    def delete_cookie!
      @cookie_jar.delete(COOKIE_NAME, path: "/", secure: @secure, same_site: :lax, httponly: true)
    end

    def fail_invalid!
      raise Identity::Error.new(:invalid_input), cause: nil
    end
  end
end
