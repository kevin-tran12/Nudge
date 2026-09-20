module Integrations
  module Cj
    # Read-only, persistence-independent CJ boundary. Fixture is the default and
    # only reachable mode unless the caller supplies both a deployment that
    # allows it and the matching explicit ModePolicy capability sentinel from
    # trusted server code (see ModePolicy) -- never a boolean, a bare ENV
    # value, or anything derived from a request. A misconfigured deployment
    # therefore degrades to fixture or fails closed; it never silently starts
    # calling CJ.
    #
    # Every live call is admitted through the shared Governor/PointsBudget
    # before dispatch, authenticated through the shared Authentication token
    # lifecycle, performed through Transport, and normalized through
    # Normalizer -- no raw provider object ever escapes this class.
    class Adapter
      # Points-per-call estimates. Only the 50-point Product List V2 cost is
      # currently confirmed by documentation evidence
      # (.planning/CJ_SCHEMA_EVIDENCE.md); the others are conservative
      # placeholders pending an owner-authorized bounded verify/record capture.
      POINTS = { product: 50, inventory: 10, freight: 10 }.freeze
      AUTH_POINTS = 1

      # product/inventory read the catalog partition; freight is consulted at
      # checkout-adjacent, fulfillment-critical points (TRD 6.2 purpose split).
      PURPOSES = { product: :catalog, inventory: :catalog, freight: :critical }.freeze

      MAX_ATTEMPTS = 3
      MAX_RETRY_DELAY = 30.0
      DEFAULT_RETRY_DELAY = 1.0

      attr_reader :mode

      def initialize(mode: :fixture, scenario: :success, deployment: Rails.env, capability: nil,
        config: Rails.application.config.x.cj, points_limit: nil, transport: nil, governor: nil,
        authentication: nil, clock: -> { Time.now.utc }, waiter: ->(seconds) { sleep(seconds) },
        observer: ->(*) { })
        policy = ModePolicy.new(deployment: deployment, mode: mode, capability: capability)
        @mode = policy.mode
        @clock = clock
        @waiter = waiter

        if @mode == :fixture
          @source = FixtureSource.new(scenario: scenario)
        else
          raise Error.new(:invalid_input), cause: nil unless config.instance_of?(Config)

          @governor = governor || Governor.new(policy: policy, points_limit: points_limit)
          @transport = transport || Transport.new
          @authentication = authentication || Authentication.new(
            credential_source: -> { config.api_key }, transport: @transport.method(:authenticate),
            governor: @governor, clock: clock, waiter: waiter, observer: observer, points: AUTH_POINTS)
        end
      end

      def product(product_id:)
        call(:product, "product_id" => identifier(product_id))
      end

      def inventory(variant_id:)
        call(:inventory, "variant_id" => identifier(variant_id))
      end

      def freight(origin_country:, destination_country:, items:)
        raise Error.new(:invalid_input) unless items.is_a?(Array) && items.size.between?(1, 100)

        rows = items.map do |item|
          unless item.is_a?(Hash) && item.size == 2 && item.key?(:quantity) && item.key?(:variant_id) &&
              item[:quantity].is_a?(Integer) && item[:quantity].between?(1, 10_000)
            raise Error.new(:invalid_input)
          end
          { "variant_id" => identifier(item[:variant_id]), "quantity" => item[:quantity] }
        end
        raise Error.new(:invalid_input) unless rows.map { |row| row["variant_id"] }.uniq.size == rows.size

        call(:freight, "origin_country" => country(origin_country),
          "destination_country" => country(destination_country), "items" => rows)
      end

      private
        def call(operation, request)
          return fixture_call(operation, request) if @mode == :fixture

          live_call(operation, request)
        end

        def fixture_call(operation, request)
          fixture = @source.read(operation, request)
          Normalizer.new.call(operation: operation, body: fixture.fetch(:body),
            request: request, observed_at: fixture.fetch(:observed_at))
        end

        # Bounded retry: only backoff-classified errors (:throttled, :unavailable)
        # are retried, up to MAX_ATTEMPTS total, and each attempt is re-admitted
        # through the governor so a retry storm cannot bypass the points/rate
        # budget. All three operations here are idempotent reads; a future
        # non-idempotent operation (e.g. order submission) must not reuse this
        # loop unmodified.
        def live_call(operation, request)
          purpose = PURPOSES.fetch(operation)
          points = POINTS.fetch(operation)
          attempt = 1
          begin
            @governor.admit!(purpose: purpose, points: points)
            token = @authentication.fetch.token
            body = @transport.call(operation: operation, token: token.value, request: request)
            Normalizer.new.call(operation: operation, body: body, request: request, observed_at: @clock.call.iso8601)
          rescue Error => error
            raise error unless error.retryable? && attempt < MAX_ATTEMPTS

            wait_before_retry(error)
            attempt += 1
            retry
          end
        end

        def wait_before_retry(error)
          delay = if error.is_a?(Governor::Throttled)
            [ [ error.retry_after, 0 ].max, MAX_RETRY_DELAY ].min
          else
            DEFAULT_RETRY_DELAY
          end
          @waiter.call(delay)
        rescue StandardError
          raise Error.new(:unavailable), cause: nil
        end

        def identifier(value)
          unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, 200) && value.match?(/\A[A-Za-z0-9_{}-]+\z/)
            raise Error.new(:invalid_input)
          end
          value.dup
        end

        def country(value)
          unless value.is_a?(String) && value.valid_encoding? && value.bytesize == 2 && value.match?(/\A[A-Z]{2}\z/)
            raise Error.new(:invalid_input)
          end

          value.dup
        end
    end
  end
end
