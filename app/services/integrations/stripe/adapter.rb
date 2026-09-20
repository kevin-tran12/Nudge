# STRIPE-SPECIFIC: removable provider integration; do not place domain logic here.

require "net/http"
require "json"
require "uri"
require "digest"

module Integrations
  module Stripe
    # Provider boundary only: create and retrieve a Stripe Checkout Session in
    # Stripe TEST mode. There is no live-money path here on purpose -- capture,
    # partial fulfillment, cancellation, and refund policy are OPEN canonical
    # decisions (see STRIPE-01 scope notes) and are never implemented, inferred,
    # or encoded in this file. Rails owns pricing and totals: this adapter only
    # accepts already-computed line items in minor units and a currency from the
    # caller; it never computes, adjusts, or looks up a price itself.
    #
    # Fixture mode is deterministic and makes zero network calls. Test-mode
    # transport calls the real Stripe REST API in test mode only, and degrades
    # to fixture behavior (rather than attempting an unauthenticated call) when
    # no secret key is configured. No raw Stripe response object escapes this
    # class: every public method returns a Result built from the fields this
    # adapter chooses to read, and the secret key is never logged, inspected,
    # or serialized (it lives only in local variables of the transport method).
    class Adapter
      API_HOST = "api.stripe.com"
      SESSIONS_PATH = "/v1/checkout/sessions"
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 5

      SESSION_ID_PATTERN = /\Acs_[A-Za-z0-9_]{8,255}\z/
      CURRENCY_PATTERN = /\A[A-Za-z]{3}\z/
      MAX_LINE_ITEMS = 100

      Result = Data.define(:id, :url, :status, :currency, :amount_total, :payment_status) do
        def inspect
          "#<#{self.class.name} id=#{id.inspect} status=#{status.inspect}>"
        end

        def as_json(*)
          {
            "id" => id, "url" => url, "status" => status,
            "currency" => currency, "amount_total" => amount_total, "payment_status" => payment_status
          }
        end

        def to_json(...)
          as_json.to_json(...)
        end
      end

      attr_reader :mode

      # The only place the mode-policy capability sentinel is supplied. Mode is
      # selected from the deployment/config snapshot (Rails.env and the frozen
      # Config read once at boot), never from an inbound request, a parameter,
      # or anything else client-controlled, mirroring
      # Integrations::ElevenLabs::Adapter. Config#test_mode? is true only when
      # the server explicitly configured test mode AND credentials are present,
      # so a misconfiguration degrades to fixture instead of failing open. An
      # explicit capability: argument (trusted server code and tests) still
      # works. There is no live-money mode to select: ModePolicy knows only
      # :fixture and :test_mode.
      def self.build(capability: nil, deployment: Rails.env, config: Rails.application.config.x.stripe,
        clock: -> { Time.current }, http_client: nil)
        capability = ModePolicy::TEST_MODE_CAPABILITY if capability.nil? && config.instance_of?(Config) && config.test_mode?
        mode = capability.nil? ? :fixture : :test_mode
        mode_policy = ModePolicy.new(deployment: deployment, mode: mode, capability: capability)
        new(mode_policy: mode_policy, config: config, clock: clock, http_client: http_client)
      end

      def initialize(mode_policy:, config:, clock: -> { Time.current }, http_client: nil)
        raise Error.new(:invalid_input), cause: nil unless mode_policy.instance_of?(ModePolicy)
        raise Error.new(:invalid_input), cause: nil unless config.instance_of?(Config)

        @mode = mode_policy.mode
        @config = config
        @clock = clock
        @http_client = http_client || method(:perform_request)
        @fixture_sessions = {}
      end

      # idempotency_key is required and is passed to Stripe as the
      # Idempotency-Key header, so a retried request cannot create a second
      # session. success_url/cancel_url are optional caller-supplied redirect
      # targets, passed through untouched.
      def create_checkout_session(line_items:, currency:, idempotency_key:, success_url: nil, cancel_url: nil)
        key = validate_idempotency_key(idempotency_key)
        cur = validate_currency(currency)
        items = validate_line_items(line_items)
        success = validate_url(success_url)
        cancel = validate_url(cancel_url)

        case effective_mode
        when :fixture
          fixture_create(items: items, currency: cur, idempotency_key: key)
        when :test_mode
          live_create(items: items, currency: cur, idempotency_key: key, success_url: success, cancel_url: cancel)
        else
          raise Error.new(:unsupported_mode), cause: nil
        end
      end

      def retrieve_checkout_session(id)
        session_id = validate_session_id(id)

        case effective_mode
        when :fixture
          fixture_retrieve(session_id)
        when :test_mode
          live_retrieve(session_id)
        else
          raise Error.new(:unsupported_mode), cause: nil
        end
      end

      private

      # :test_mode with no configured secret key degrades to fixture behavior
      # rather than attempting an unauthenticated call to Stripe.
      def effective_mode
        return :fixture if @mode == :test_mode && !@config.credentials_present?

        @mode
      end

      # -- validation -----------------------------------------------------
      # Format/shape validation only. Never a pricing decision: amounts and
      # currency arrive already computed by the caller (Rails); this adapter
      # only checks they look like well-formed minor-unit integers.

      def validate_idempotency_key(value)
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(String) && value.length.between?(1, 255)

        value.dup.freeze
      end

      def validate_currency(value)
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(String) && value.match?(CURRENCY_PATTERN)

        value.downcase.freeze
      end

      def validate_url(value)
        return nil if value.nil?
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(String) && value.match?(%r{\Ahttps?://})

        value.dup.freeze
      end

      def validate_line_items(value)
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(Array) && value.present? && value.size <= MAX_LINE_ITEMS

        value.map { |item| validate_line_item(item) }.freeze
      end

      def validate_line_item(item)
        raise Error.new(:invalid_input), cause: nil unless item.is_a?(Hash)

        name = item[:name].nil? ? item["name"] : item[:name]
        amount = item.key?(:amount) ? item[:amount] : item["amount"]
        quantity = item.key?(:quantity) ? item[:quantity] : item["quantity"]
        quantity = 1 if quantity.nil?

        raise Error.new(:invalid_input), cause: nil unless name.is_a?(String) && !name.strip.empty? && name.bytesize <= 5_000
        raise Error.new(:invalid_input), cause: nil unless amount.is_a?(Integer) && amount >= 0
        raise Error.new(:invalid_input), cause: nil unless quantity.is_a?(Integer) && quantity >= 1

        { name: name.dup.freeze, amount: amount, quantity: quantity }.freeze
      end

      def validate_session_id(value)
        raise Error.new(:invalid_input), cause: nil unless value.is_a?(String) && value.match?(SESSION_ID_PATTERN)

        value.dup.freeze
      end

      # -- fixture mode -----------------------------------------------------
      # Deterministic on idempotency_key alone: repeated creation with the same
      # key returns the same in-memory session rather than a new one, mirroring
      # a well-behaved idempotency implementation for this narrow boundary.

      def fixture_create(items:, currency:, idempotency_key:)
        id = "cs_test_fixture_#{Digest::SHA256.hexdigest(idempotency_key)[0, 24]}"
        @fixture_sessions[id] ||= Result.new(
          id: id.freeze,
          url: "https://checkout.stripe.test/fixture/#{id}".freeze,
          status: "open".freeze,
          currency: currency,
          amount_total: items.sum { |item| item[:amount] * item[:quantity] },
          payment_status: "unpaid".freeze
        ).freeze
      end

      def fixture_retrieve(session_id)
        @fixture_sessions.fetch(session_id) { raise Error.new(:not_found), cause: nil }
      end

      # -- test-mode transport ----------------------------------------------

      def live_create(items:, currency:, idempotency_key:, success_url:, cancel_url:)
        secret_key = @config.secret_key
        raise Error.new(:missing_credentials), cause: nil unless secret_key.is_a?(String) && !secret_key.empty?

        params = build_create_params(items: items, currency: currency, success_url: success_url, cancel_url: cancel_url)
        body = @http_client.call(http_method: :post, path: SESSIONS_PATH, secret_key: secret_key,
          idempotency_key: idempotency_key, params: params)
        build_result(body)
      rescue Error
        raise
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end

      def live_retrieve(session_id)
        secret_key = @config.secret_key
        raise Error.new(:missing_credentials), cause: nil unless secret_key.is_a?(String) && !secret_key.empty?

        body = @http_client.call(http_method: :get, path: "#{SESSIONS_PATH}/#{session_id}", secret_key: secret_key,
          idempotency_key: nil, params: nil)
        build_result(body)
      rescue Error
        raise
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end

      def build_create_params(items:, currency:, success_url:, cancel_url:)
        params = { "mode" => "payment" }
        params["success_url"] = success_url if success_url
        params["cancel_url"] = cancel_url if cancel_url
        items.each_with_index do |item, index|
          params["line_items[#{index}][quantity]"] = item[:quantity]
          params["line_items[#{index}][price_data][currency]"] = currency
          params["line_items[#{index}][price_data][unit_amount]"] = item[:amount]
          params["line_items[#{index}][price_data][product_data][name]"] = item[:name]
        end
        params
      end

      def build_result(body)
        raise Error.new(:malformed_response), cause: nil unless body.is_a?(Hash)

        id = body["id"]
        raise Error.new(:malformed_response), cause: nil unless id.is_a?(String) && id.bytesize.between?(1, 512)

        Result.new(
          id: id.dup.freeze,
          url: string_or_nil(body["url"]),
          status: string_or_nil(body["status"]),
          currency: string_or_nil(body["currency"]),
          amount_total: body["amount_total"].is_a?(Integer) ? body["amount_total"] : nil,
          payment_status: string_or_nil(body["payment_status"])
        ).freeze
      end

      def string_or_nil(value)
        value.is_a?(String) ? value.dup.freeze : nil
      end

      # Real network transport. Only reached in :test_mode, which is unreachable
      # without an explicit TEST_MODE_CAPABILITY sentinel from trusted server
      # code, and which itself degrades to fixture when no secret key is set.
      def perform_request(http_method:, path:, secret_key:, idempotency_key: nil, params: nil)
        uri = URI::HTTPS.build(host: API_HOST, path: path)
        request = case http_method
        when :post
          req = Net::HTTP::Post.new(uri)
          req.body = URI.encode_www_form(params || {})
          req
        when :get
          Net::HTTP::Get.new(uri)
        else
          raise Error.new(:invalid_input), cause: nil
        end
        request["Authorization"] = "Bearer #{secret_key}"
        request["Accept"] = "application/json"
        request["Idempotency-Key"] = idempotency_key if idempotency_key

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }

        case response
        when Net::HTTPSuccess
          JSON.parse(response.body)
        when Net::HTTPUnauthorized, Net::HTTPForbidden
          raise Error.new(:authentication_failed), cause: nil
        when Net::HTTPTooManyRequests, Net::HTTPServerError
          raise Error.new(:unavailable), cause: nil
        else
          raise Error.new(:provider_rejected), cause: nil
        end
      rescue JSON::ParserError
        raise Error.new(:malformed_response), cause: nil
      rescue Error
        raise
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end
    end
  end
end
