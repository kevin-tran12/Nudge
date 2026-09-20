require "test_helper"
require "net/http"

class StripeAdapterTest < ActiveSupport::TestCase
  LINE_ITEMS = [ { name: "Widget", amount: 1_500, quantity: 2 } ].freeze

  test "fixture mode is deterministic and makes zero network calls or database queries" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*event| queries << event }
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "Stripe fixture attempted HTTP" }

    adapter = fixture_adapter
    first = adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "idem-key-1")
    second = adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "idem-key-1")

    assert_equal :fixture, adapter.mode
    assert_equal first.id, second.id
    assert_equal 3_000, first.amount_total
    assert_match(/\Acs_/, first.id)

    retrieved = adapter.retrieve_checkout_session(first.id)
    assert_equal first.id, retrieved.id
    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  test "the same idempotency key never creates a second fixture session" do
    adapter = fixture_adapter
    first = adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "shared-key")
    other_items = [ { name: "Different", amount: 999, quantity: 1 } ]
    second = adapter.create_checkout_session(line_items: other_items, currency: "usd", idempotency_key: "shared-key")

    assert_equal first.id, second.id
    assert_equal first.amount_total, second.amount_total
  end

  test "idempotency key is required for session creation" do
    adapter = fixture_adapter
    assert_error(:invalid_input) { adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: nil) }
    assert_error(:invalid_input) { adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "") }
  end

  test "idempotency key is actually sent to the transport as a header on create" do
    captured = nil
    adapter = test_mode_adapter(http_client: lambda do |http_method:, path:, secret_key:, idempotency_key:, params:|
      captured = idempotency_key
      { "id" => "cs_test_live123", "url" => "https://checkout.stripe.com/pay/cs_test_live123",
        "status" => "open", "currency" => "usd", "amount_total" => 3_000, "payment_status" => "unpaid" }
    end)

    adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "sent-key-42")
    assert_equal "sent-key-42", captured
  end

  test "test mode is unreachable without the capability marker in every deployment" do
    [ :test, :development, :staging ].each do |deployment|
      assert_error(:unsupported_mode) do
        Integrations::Stripe::Adapter.new(
          mode_policy: Integrations::Stripe::ModePolicy.new(deployment: deployment, mode: :test_mode),
          config: config_for
        )
      end
    end
  end

  test "Adapter.build only reaches test_mode when the capability sentinel is supplied" do
    fixture = Integrations::Stripe::Adapter.build(deployment: :development, config: config_for)
    assert_equal :fixture, fixture.mode

    live = Integrations::Stripe::Adapter.build(
      capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY,
      deployment: :development, config: config_for
    )
    assert_equal :test_mode, live.mode
  end

  test "test mode without credentials degrades to fixture rather than calling out" do
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "Stripe degraded test-mode attempted HTTP" }

    adapter = test_mode_adapter(config: config_for(secret_key: nil), http_client: ->(**) { raise "must not be called" })
    result = adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "idem-1")

    assert_match(/\Acs_test_fixture_/, result.id)
    assert_equal :test_mode, adapter.mode
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  test "test mode surfaces a typed error and never leaks the transport body" do
    adapter = test_mode_adapter(http_client: ->(**) { raise "boom SYNTHETIC-SECRET-VALUE" })
    error = assert_error(:unavailable) { adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "idem-1") }
    refute_includes error.message, "SYNTHETIC-SECRET-VALUE"
  end

  test "test mode returns a typed Result and no raw provider hash escapes the adapter" do
    adapter = test_mode_adapter(http_client: lambda do |**|
      { "id" => "cs_test_abc123", "url" => "https://checkout.stripe.com/pay/cs_test_abc123",
        "status" => "open", "currency" => "usd", "amount_total" => 3_000, "payment_status" => "unpaid",
        "client_secret" => "should-not-appear", "payment_intent" => "pi_should_not_appear" }
    end)

    result = adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "idem-1")
    assert_instance_of Integrations::Stripe::Adapter::Result, result
    refute_respond_to result, :client_secret
    refute_respond_to result, :payment_intent
    assert_equal %i[id url status currency amount_total payment_status].sort, result.to_h.keys.sort
  end

  test "test mode rejects a malformed transport payload" do
    adapter = test_mode_adapter(http_client: ->(**) { { "id" => 12345 } })
    assert_error(:malformed_response) { adapter.create_checkout_session(line_items: LINE_ITEMS, currency: "usd", idempotency_key: "idem-1") }
  end

  test "amounts must be non-negative integer minor units" do
    adapter = fixture_adapter
    [ -1, 1.5, "1500", nil, true ].each do |bad_amount|
      assert_error(:invalid_input) do
        adapter.create_checkout_session(
          line_items: [ { name: "Widget", amount: bad_amount, quantity: 1 } ],
          currency: "usd", idempotency_key: "idem-1"
        )
      end
    end
  end

  test "a decimal-dollar client-supplied-looking price is rejected" do
    adapter = fixture_adapter
    assert_error(:invalid_input) do
      adapter.create_checkout_session(
        line_items: [ { name: "Widget", amount: 19.99, quantity: 1 } ],
        currency: "usd", idempotency_key: "idem-1"
      )
    end
  end

  test "currency must be a valid three-letter code" do
    adapter = fixture_adapter
    [ "US", "USDD", "12A", nil, "" ].each do |bad_currency|
      assert_error(:invalid_input) do
        adapter.create_checkout_session(line_items: LINE_ITEMS, currency: bad_currency, idempotency_key: "idem-1")
      end
    end
  end

  test "line items must be present and well formed" do
    adapter = fixture_adapter
    assert_error(:invalid_input) { adapter.create_checkout_session(line_items: [], currency: "usd", idempotency_key: "idem-1") }
    assert_error(:invalid_input) { adapter.create_checkout_session(line_items: nil, currency: "usd", idempotency_key: "idem-1") }
    assert_error(:invalid_input) do
      adapter.create_checkout_session(line_items: [ { name: "", amount: 100, quantity: 1 } ], currency: "usd", idempotency_key: "idem-1")
    end
  end

  test "retrieving an unknown fixture session id fails closed" do
    adapter = fixture_adapter
    assert_error(:not_found) { adapter.retrieve_checkout_session("cs_test_fixture_doesnotexist00000000") }
  end

  test "retrieving a malformed session id fails closed" do
    adapter = fixture_adapter
    assert_error(:invalid_input) { adapter.retrieve_checkout_session("not-a-real-session-id") }
  end

  test "Config never exposes the secret key through inspect, to_s, as_json, or to_json" do
    config = config_for(secret_key: "sk_test_super_secret_value")

    refute_includes config.inspect, "sk_test_super_secret_value"
    refute_includes config.to_s, "sk_test_super_secret_value"
    refute_includes config.as_json.to_s, "sk_test_super_secret_value"
    refute_includes config.to_json, "sk_test_super_secret_value"
  end

  test "Error never exposes provider-supplied content in inspect, to_s, as_json, or to_json" do
    error = Integrations::Stripe::Error.new(:authentication_failed)

    refute_match(/sk_test_/, error.inspect)
    refute_match(/sk_test_/, error.to_s)
    refute_match(/sk_test_/, error.as_json.to_s)
    refute_match(/sk_test_/, error.to_json)
    assert_equal :authentication_failed, error.code
  end

  private

  def fixture_adapter
    Integrations::Stripe::Adapter.new(
      mode_policy: Integrations::Stripe::ModePolicy.new(deployment: :test),
      config: config_for
    )
  end

  def test_mode_adapter(config: config_for, http_client: nil)
    Integrations::Stripe::Adapter.new(
      mode_policy: Integrations::Stripe::ModePolicy.new(deployment: :development, mode: :test_mode,
        capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY),
      config: config, http_client: http_client
    )
  end

  def config_for(secret_key: "sk_test_key", webhook_secret: "whsec_test_secret", mode: "fixture")
    Integrations::Stripe::Config.new(secret_key: secret_key, webhook_secret: webhook_secret, mode: mode)
  end

  def assert_error(code, &block)
    error = assert_raises(Integrations::Stripe::Error, &block)
    assert_equal code, error.code
    error
  end
end
