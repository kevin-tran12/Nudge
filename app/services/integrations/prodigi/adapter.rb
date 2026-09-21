require "json"

module Integrations
  module Prodigi
    # Read-only-from-the-caller's-perspective Prodigi boundary. Fixture is
    # the default and only reachable mode unless the caller supplies both a
    # deployment that allows it and the matching explicit ModePolicy
    # capability sentinel from trusted server code (see ModePolicy) -- never
    # a boolean, a bare ENV value, or anything derived from a request. A
    # misconfigured deployment therefore degrades to fixture or fails
    # closed; it never silently starts calling Prodigi.
    #
    # This phase has no Normalizer/Contracts layer yet (those need real
    # captured Prodigi responses to derive an accurate field allowlist from
    # -- see lib/tasks/prodigi.rake and the CJ precedent this repo already
    # learned that lesson from), so every public method returns the raw
    # parsed-and-frozen provider payload rather than a typed Result.
    class Adapter
      # Default sandbox-mode raw-response sink: discards the bytes. Only an
      # explicitly injected sink (trusted server code, or the capture rake
      # task) ever sees them.
      NO_RAW_SINK = ->(operation:, request:, body:, observed_at:) { }

      MAX_ATTEMPTS = 3
      MAX_RETRY_DELAY = 30.0
      DEFAULT_RETRY_DELAY = 1.0

      ID_PATTERN = /\A[A-Za-z0-9_-]+\z/
      COUNTRY_PATTERN = /\A[A-Z]{2}\z/
      CURRENCY_PATTERN = /\A[A-Z]{3}\z/
      URL_PATTERN = %r{\Ahttps?://}
      # Documented Prodigi shipping-method values. Not exhaustive of every
      # SKU-specific option Prodigi may offer, but a deliberate allowlist
      # beats accepting an arbitrary string this adapter cannot verify.
      SHIPPING_METHODS = %w[Budget Standard Express Overnight].freeze
      DEFAULT_SHIPPING_METHOD = "Standard"
      MAX_ID_BYTES = 200
      MAX_ITEMS = 100
      MAX_REFERENCE_BYTES = 255

      # create_order maps to the :order fixture/capture file; every other
      # operation's transport name matches its fixture file name directly.
      FIXTURE_OPERATIONS = { product: :product, quote: :quote, create_order: :order, order_status: :order_status }.freeze

      attr_reader :mode

      # The only place the mode-policy capability sentinel is auto-supplied.
      # Mode is selected from the deployment/config snapshot (Rails.env and
      # the frozen Config read once at boot), never from an inbound request,
      # mirroring Integrations::Stripe::Adapter.build. Config#sandbox? is
      # true only when the server explicitly configured sandbox mode AND
      # credentials are present, so a misconfiguration degrades to fixture
      # instead of failing open into a provider call it cannot authenticate.
      # An explicit capability: argument (trusted server code and tests)
      # still works without a sandbox-configured Config.
      def self.build(capability: nil, deployment: Rails.env, config: Rails.application.config.x.prodigi,
        transport: nil, pacer: nil, waiter: ->(seconds) { sleep(seconds) }, raw_sink: NO_RAW_SINK)
        capability = ModePolicy::SANDBOX_CAPABILITY if capability.nil? && config.instance_of?(Config) && config.sandbox?
        mode = capability.nil? ? :fixture : :sandbox
        new(mode: mode, deployment: deployment, capability: capability, config: config,
          transport: transport, pacer: pacer, waiter: waiter, raw_sink: raw_sink)
      end

      def initialize(mode: :fixture, scenario: :success, deployment: Rails.env, capability: nil,
        config: Rails.application.config.x.prodigi, transport: nil, pacer: nil,
        waiter: ->(seconds) { sleep(seconds) }, raw_sink: NO_RAW_SINK)
        policy = ModePolicy.new(deployment: deployment, mode: mode, capability: capability)
        raise Error.new(:invalid_input), cause: nil unless raw_sink.respond_to?(:call)

        @mode = policy.mode
        @waiter = waiter
        @raw_sink = raw_sink

        if @mode == :fixture
          @source = FixtureSource.new(scenario: scenario)
        else
          raise Error.new(:invalid_input), cause: nil unless config.instance_of?(Config)
          raise Error.new(:missing_credentials), cause: nil unless config.credentials_present?

          @api_key = config.api_key
          @transport = transport || Transport.new
          @pacer = pacer || Pacer.new
        end
      end

      def product(sku:)
        call(:product, { "sku" => identifier(sku) })
      end

      def quote(destination_country:, items:, shipping_method: nil, currency: "USD")
        request = {
          "destination_country" => country(destination_country),
          "shipping_method" => shipping_method_value(shipping_method),
          "currency" => currency_code(currency),
          "items" => order_line_items(items)
        }
        call(:quote, request)
      end

      # idempotency_key is remembered indefinitely per account by Prodigi
      # itself: this method deliberately accepts no unknown top-level field
      # (Ruby's keyword-argument mechanism rejects one on its own) and never
      # retries internally -- see the comment in #call below for why.
      def create_order(merchant_reference:, shipping_method:, recipient:, items:, idempotency_key:,
        callback_url: nil, metadata: nil)
        request = {
          "merchant_reference" => reference(merchant_reference),
          "shipping_method" => shipping_method_value(shipping_method, allow_nil: false),
          "recipient" => recipient_hash(recipient),
          "items" => order_line_items(items),
          "idempotency_key" => reference(idempotency_key),
          "callback_url" => optional_url(callback_url),
          "metadata" => optional_metadata(metadata)
        }.compact
        call(:create_order, request)
      end

      def order_status(order_id:)
        call(:order_status, { "order_id" => identifier(order_id) })
      end

      private

      def call(operation, request)
        return fixture_call(operation, request) if @mode == :fixture

        # create_order must NEVER retry inside this adapter, even on the
        # exact same retryable error class that product/quote/order_status
        # legitimately retry past. Prodigi remembers idempotencyKey
        # indefinitely per account, so it is the CALLER's retry with that
        # same key that is safe -- an adapter-internal retry would defeat
        # that guarantee: if something upstream mutated request args between
        # attempts, a silent internal retry could send two different bodies
        # under one idempotency key, and Prodigi has no way to detect that
        # from its side. Every other operation here is an idempotent
        # read/lookup, so it may retry through the normal bounded loop.
        return perform_once(operation, request) if operation == :create_order

        perform_with_retry(operation, request)
      end

      def fixture_call(operation, request)
        fixture = @source.read(FIXTURE_OPERATIONS.fetch(operation), request)
        JSON.parse(fixture.fetch(:body)).freeze
      rescue JSON::ParserError
        raise Error.new(:malformed_response), cause: nil
      end

      def perform_with_retry(operation, request)
        attempt = 1
        begin
          perform_once(operation, request)
        rescue Error => error
          raise error unless error.retryable? && attempt < MAX_ATTEMPTS

          wait_before_retry(error)
          attempt += 1
          retry
        end
      end

      def perform_once(operation, request)
        @pacer.throttle!
        body = @transport.call(operation: operation, api_key: @api_key, request: request)
        observed_at = Time.now.utc.iso8601
        @raw_sink.call(operation: operation, request: request, body: body, observed_at: observed_at)
        JSON.parse(body).freeze
      rescue JSON::ParserError
        raise Error.new(:malformed_response), cause: nil
      end

      def wait_before_retry(error)
        delay = [ [ error.retry_after || DEFAULT_RETRY_DELAY, 0 ].max, MAX_RETRY_DELAY ].min
        @waiter.call(delay)
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end

      # -- validation -----------------------------------------------------
      # Format/shape validation only, mirroring Integrations::Cj::Adapter's
      # style. Deep-stringifies caller-supplied symbol keys so the same
      # request hash can be exact-matched by FixtureSource and JSON-encoded
      # by Transport without a separate wire-translation step.

      def identifier(value)
        unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, MAX_ID_BYTES) && value.match?(ID_PATTERN)
          raise Error.new(:invalid_input), cause: nil
        end

        value.dup
      end

      def country(value)
        unless value.is_a?(String) && value.valid_encoding? && value.bytesize == 2 && value.match?(COUNTRY_PATTERN)
          raise Error.new(:invalid_input), cause: nil
        end

        value.dup
      end

      def currency_code(value)
        unless value.is_a?(String) && value.valid_encoding? && value.match?(CURRENCY_PATTERN)
          raise Error.new(:invalid_input), cause: nil
        end

        value.dup
      end

      def reference(value)
        unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, MAX_REFERENCE_BYTES)
          raise Error.new(:invalid_input), cause: nil
        end

        value.dup
      end

      # nil defaults to Prodigi's standard shipping tier so a caller-omitted
      # shipping_method still resolves to one concrete, documented value on
      # the wire rather than sending a null the provider would have to guess
      # about. create_order requires the field explicitly (allow_nil: false)
      # since it is a required keyword there.
      def shipping_method_value(value, allow_nil: true)
        return DEFAULT_SHIPPING_METHOD if value.nil? && allow_nil
        unless value.is_a?(String) && SHIPPING_METHODS.include?(value)
          raise Error.new(:invalid_input), cause: nil
        end

        value.dup
      end

      def optional_url(value)
        return nil if value.nil?
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(String) && value.match?(URL_PATTERN)

        value.dup
      end

      def optional_metadata(value)
        return nil if value.nil?
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(Hash)

        stringify(value)
      end

      def order_line_items(value)
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(Array) && value.size.between?(1, MAX_ITEMS)

        value.map { |item| order_line_item(item) }
      end

      def order_line_item(item)
        raise Error.new(:invalid_input), cause: nil unless item.is_a?(Hash)

        sku = fetch_field(item, :sku)
        copies = fetch_field(item, :copies)
        unless sku.is_a?(String) && sku.valid_encoding? && sku.bytesize.between?(1, MAX_ID_BYTES) && sku.match?(ID_PATTERN)
          raise Error.new(:invalid_input), cause: nil
        end
        raise Error.new(:invalid_input), cause: nil unless copies.is_a?(Integer) && copies.between?(1, 10_000)

        stringify(item)
      end

      def recipient_hash(value)
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(Hash)

        name = fetch_field(value, :name)
        raise Error.new(:invalid_input), cause: nil unless name.is_a?(String) && !name.strip.empty?

        { "name" => name.dup, "address" => address_hash(fetch_field(value, :address)) }
      end

      def address_hash(value)
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(Hash)

        line1 = fetch_field(value, :line1)
        country_code = fetch_field(value, :countryCode)
        raise Error.new(:invalid_input), cause: nil unless line1.is_a?(String) && !line1.strip.empty?
        raise Error.new(:invalid_input), cause: nil unless country_code.is_a?(String) && country_code.match?(COUNTRY_PATTERN)

        stringify(value)
      end

      def fetch_field(hash, key)
        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), memo| memo[key.to_s] = stringify(child) }
        when Array
          value.map { |child| stringify(child) }
        else
          value
        end
      end
    end
  end
end
