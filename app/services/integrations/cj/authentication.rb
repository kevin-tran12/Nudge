module Integrations
  module Cj
    # Process-local token lifecycle for a future CJ transport. Credential lookup,
    # provider I/O, time, waiting, and observation are injected; this class never
    # reads environment variables or logs credentials and tokens.
    #
    # Paused state and the token cache are intentionally not durable. A later
    # transport package must add deployment-wide coordination and alert routing.
    class Authentication
      MAX_TOKEN_LIFETIME = 180 * 24 * 60 * 60
      DEFAULT_REFRESH_BEFORE = 7 * 24 * 60 * 60
      MIN_RETRY_DELAY = 1.0
      MAX_INLINE_RETRY_DELAY = 30.0
      RESULT_CODES = %i[cached refreshed].freeze
      TERMINAL_CODES = %i[authentication_failed malformed_response].freeze

      class Token
        attr_reader :value, :expires_at

        def initialize(value:, expires_at:)
          @value = value.dup.freeze
          @expires_at = expires_at.dup.freeze
          freeze
        end

        def refresh_due?(now, refresh_before)
          expires_at <= now + refresh_before
        end

        def inspect
          "#<#{self.class.name} value=[FILTERED] expires_at=#{expires_at.iso8601}>"
        end

        def as_json(*)
          { "expires_at" => expires_at.iso8601 }
        end

        def to_json(options = nil)
          as_json.to_json(options)
        end
      end

      class Result
        attr_reader :code, :token

        def initialize(code:, token:)
          raise Error.new(:invalid_input), cause: nil unless RESULT_CODES.include?(code) && token.instance_of?(Token)

          @code = code
          @token = token
          freeze
        end

        def inspect
          "#<#{self.class.name} code=#{code.inspect} token=#{token.inspect}>"
        end

        def as_json(*)
          { "code" => code.to_s, "token" => token.as_json }
        end

        def to_json(options = nil)
          as_json.to_json(options)
        end
      end

      def initialize(credential_source:, transport:, governor:, clock: -> { Time.now.utc },
        waiter: ->(seconds) { sleep(seconds) }, observer: ->(*) { }, refresh_before: DEFAULT_REFRESH_BEFORE,
        points:, max_attempts: 2)
        callables = [ credential_source, transport, clock, waiter, observer ]
        unless callables.all? { |callable| callable.respond_to?(:call) } && governor.instance_of?(Governor) &&
            valid_duration?(refresh_before) && refresh_before.positive? && refresh_before < MAX_TOKEN_LIFETIME &&
            points.is_a?(Integer) && points.positive? &&
            max_attempts.is_a?(Integer) && max_attempts.between?(1, 3)
          raise Error.new(:invalid_input), cause: nil
        end

        @credential_source = credential_source
        @transport = transport
        @governor = governor
        @clock = clock
        @waiter = waiter
        @observer = observer
        @refresh_before = refresh_before
        @points = points
        @max_attempts = max_attempts
        @mutex = Mutex.new
        @paused = false
        @pause_code = nil
      end

      def fetch
        @mutex.synchronize do
          raise Error.new(@pause_code), cause: nil if @paused

          now = trusted_now
          if @token && !@token.refresh_due?(now, @refresh_before)
            observe(:token_reused)
            return Result.new(code: :cached, token: @token)
          end

          refresh
        end
      end

      def paused?
        @mutex.synchronize { @paused }
      end

      def recover!
        @mutex.synchronize do
          @paused = false
          @pause_code = nil
          @token = nil
          observe(:authentication_recovered)
        end
        true
      end

      private
        def refresh
          observe(:refresh_started)

          1.upto(@max_attempts) do |attempt|
            begin
              admission = @governor.admit!(purpose: :recovery, points: @points)
              raise Error.new(:unsupported_mode), cause: nil if admission.mode == :fixture

              credential = @credential_source.call
              raise Error.new(:authentication_failed), cause: nil if credential.nil?

              response = @transport.call(credential: credential)
              @token = token_from(response, trusted_now)
              observe(:refresh_succeeded, attempt:)
              return Result.new(code: :refreshed, token: @token)
            rescue Error => error
              sanitized = sanitize(error)
              return fail_attempt!(sanitized) if TERMINAL_CODES.include?(sanitized.code)
              raise sanitized, cause: nil unless retryable?(sanitized, attempt)

              delay = retry_delay(sanitized)
              observe(:refresh_retry, attempt:, code: sanitized.code, retry_after: delay)
              wait(delay)
            rescue StandardError
              sanitized = Error.new(:unavailable)
              raise sanitized, cause: nil unless retryable?(sanitized, attempt)

              delay = retry_delay(sanitized)
              observe(:refresh_retry, attempt:, code: sanitized.code, retry_after: delay)
              wait(delay)
            end
          end
        end

        def token_from(response, now)
          unless response.is_a?(Hash) && response.key?(:value) && response.key?(:expires_at)
            raise Error.new(:malformed_response), cause: nil
          end

          value = response[:value]
          expires_at = response[:expires_at]
          unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
              value.bytesize.between?(1, 8_192) &&
              !value.match?(/[[:cntrl:]]/) && expires_at.instance_of?(Time)
            raise Error.new(:malformed_response), cause: nil
          end
          raise Error.new(:authentication_failed), cause: nil unless expires_at > now
          raise Error.new(:malformed_response), cause: nil if expires_at <= now + @refresh_before

          Token.new(value:, expires_at: [ expires_at, now + MAX_TOKEN_LIFETIME ].min)
        end

        def trusted_now
          now = @clock.call
          unless now.instance_of?(Time) && (@last_seen_at.nil? || now >= @last_seen_at)
            raise Error.new(:unavailable), cause: nil
          end

          @last_seen_at = now
        rescue StandardError
          raise Error.new(:unavailable), cause: nil
        end

        def sanitize(error)
          if error.is_a?(Governor::Throttled) && valid_duration?(error.retry_after)
            Governor::Throttled.new(error.retry_after)
          else
            Error.new(error.code)
          end
        rescue StandardError
          Error.new(:unavailable)
        end

        def retryable?(error, attempt)
          error.retryable? && attempt < @max_attempts &&
            (!error.is_a?(Governor::Throttled) || error.retry_after <= MAX_INLINE_RETRY_DELAY)
        end

        def retry_delay(error)
          return MIN_RETRY_DELAY unless error.is_a?(Governor::Throttled)

          [ error.retry_after, MIN_RETRY_DELAY ].max
        end

        def wait(seconds)
          @waiter.call(seconds)
        rescue StandardError
          raise Error.new(:unavailable), cause: nil
        end

        def fail_attempt!(error)
          @paused = true
          @pause_code = error.code
          @token = nil
          observe(:authentication_paused, code: error.code)
          raise error, cause: nil
        end

        def observe(event, **attributes)
          @observer.call(event, attributes.freeze)
        rescue StandardError
          nil
        end

        def valid_duration?(value)
          (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? && value >= 0
        end
    end
  end
end
