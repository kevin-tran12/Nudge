require "test_helper"
require "json"

class ProdigiAdapterTest < ActiveSupport::TestCase
  VALID_ORDER_ARGS = {
    merchant_reference: "order-ref-1",
    shipping_method: "Standard",
    recipient: { name: "Jane Doe", address: { line1: "1 Main St", postalOrZipCode: "94103", countryCode: "US" } },
    items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1 } ],
    idempotency_key: "idem-key-1"
  }.freeze

  # -- fixture mode ------------------------------------------------------

  test "fixture mode is deterministic and never invokes the pacer, transport, or raw_sink" do
    pacer = Object.new
    pacer.define_singleton_method(:throttle!) { flunk "fixture mode must never consult the pacer" }
    sink_calls = 0
    sink = ->(**) { sink_calls += 1 }

    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture, pacer: pacer, raw_sink: sink)
    first = adapter.product(sku: "GLOBAL-CFPM-16X24")
    second = adapter.product(sku: "GLOBAL-CFPM-16X24")

    assert_equal :fixture, adapter.mode
    assert_equal first, second
    assert_equal 0, sink_calls
  end

  test "fixture results are frozen so no caller can mutate a shared payload" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    result = adapter.product(sku: "GLOBAL-CFPM-16X24")

    assert result.frozen?
    assert_raises(FrozenError) { result["outcome"] = "Mutated" }
  end

  test "a fixture request with no matching entry is a fixture_miss" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    error = assert_raises(Integrations::Prodigi::Error) { adapter.product(sku: "does-not-exist") }
    assert_equal :fixture_miss, error.code
  end

  test "all nonfixture modes and unknown fixture scenarios fail closed in the test deployment" do
    [ :sandbox, :live, :unknown, nil, "FIXTURE" ].each do |mode|
      assert_raises(Integrations::Prodigi::Error) { Integrations::Prodigi::Adapter.new(mode: mode) }
    end
    assert_raises(Integrations::Prodigi::Error) { Integrations::Prodigi::Adapter.new(scenario: "../../anything") }
    assert_equal :fixture, Integrations::Prodigi::Adapter.new(mode: "fixture").mode
  end

  # -- sandbox construction ------------------------------------------------

  test "sandbox mode without a present credential fails closed at construction" do
    error = assert_raises(Integrations::Prodigi::Error) do
      Integrations::Prodigi::Adapter.new(mode: :sandbox, deployment: :development,
        capability: Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY,
        config: Integrations::Prodigi::Config.new(api_key: nil, mode: "sandbox"))
    end
    assert_equal :missing_credentials, error.code
  end

  test "an raw_sink that does not respond to call is rejected" do
    error = assert_raises(Integrations::Prodigi::Error) { Integrations::Prodigi::Adapter.new(mode: :fixture, raw_sink: "not-callable") }
    assert_equal :invalid_input, error.code
  end

  # -- retry behavior: product/quote/order_status may retry ---------------

  test "product retries once on a throttled transport error and then succeeds, deterministically" do
    calls = 0
    transport = fake_transport do |**|
      calls += 1
      raise Integrations::Prodigi::Error.new(:throttled) if calls == 1
      JSON.generate(success_product_body)
    end
    waits = []
    adapter = sandbox_adapter(transport: transport, waiter: ->(seconds) { waits << seconds })

    result = adapter.product(sku: "GLOBAL-CFPM-16X24")

    assert_equal 2, calls
    assert_equal 1, waits.size
    assert_equal "Ok", result["outcome"]
  end

  test "quote retries on an unavailable transport error and then succeeds, deterministically" do
    calls = 0
    transport = fake_transport do |**|
      calls += 1
      raise Integrations::Prodigi::Error.new(:unavailable) if calls == 1
      JSON.generate(success_quote_body)
    end
    adapter = sandbox_adapter(transport: transport, waiter: ->(_seconds) { })

    result = adapter.quote(destination_country: "US", items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1 } ])

    assert_equal 2, calls
    assert_equal "Created", result["outcome"]
  end

  test "order_status retries on a throttled transport error and then succeeds, deterministically" do
    calls = 0
    transport = fake_transport do |**|
      calls += 1
      raise Integrations::Prodigi::Error.new(:throttled) if calls == 1
      JSON.generate(success_order_status_body)
    end
    adapter = sandbox_adapter(transport: transport, waiter: ->(_seconds) { })

    result = adapter.order_status(order_id: "ord_fixture_1")

    assert_equal 2, calls
    assert_equal "ord_fixture_1", result.dig("order", "id")
  end

  test "retries are bounded by MAX_ATTEMPTS and the error surfaces once exhausted" do
    calls = 0
    transport = fake_transport { |**| calls += 1; raise Integrations::Prodigi::Error.new(:unavailable) }
    adapter = sandbox_adapter(transport: transport, waiter: ->(_seconds) { })

    assert_raises(Integrations::Prodigi::Error) { adapter.product(sku: "GLOBAL-CFPM-16X24") }
    assert_equal Integrations::Prodigi::Adapter::MAX_ATTEMPTS, calls
  end

  test "a non-retryable transport error (e.g. validation_failed) is never retried" do
    calls = 0
    transport = fake_transport { |**| calls += 1; raise Integrations::Prodigi::Error.new(:validation_failed) }
    adapter = sandbox_adapter(transport: transport, waiter: ->(_seconds) { flunk "must not wait to retry a non-retryable error" })

    error = assert_raises(Integrations::Prodigi::Error) { adapter.product(sku: "GLOBAL-CFPM-16X24") }
    assert_equal :validation_failed, error.code
    assert_equal 1, calls
  end

  # -- the central behavioral property of this phase -----------------------
  # create_order must NEVER retry inside the adapter, even on the exact same
  # retryable error class that product/quote/order_status legitimately retry.
  # Prodigi remembers idempotencyKey indefinitely per account, so it is the
  # CALLER's retry with that same key that is safe -- an adapter-internal
  # retry would defeat that guarantee (if something upstream mutated the
  # request between attempts, a silent internal retry could send two
  # different bodies under one idempotency key, and Prodigi cannot detect
  # that from its side).

  test "create_order never retries even on a retryable transport error" do
    calls = 0
    transport = fake_transport { |**| calls += 1; raise Integrations::Prodigi::Error.new(:throttled) }
    adapter = sandbox_adapter(transport: transport, waiter: ->(_seconds) { flunk "create_order must never wait to retry" })

    error = assert_raises(Integrations::Prodigi::Error) { adapter.create_order(**VALID_ORDER_ARGS) }

    assert_equal :throttled, error.code
    assert_equal 1, calls, "create_order must call the transport exactly once -- it must never retry internally"
  end

  test "the identical retryable failure is retried for a read but never for create_order" do
    read_calls = 0
    read_transport = fake_transport do |**|
      read_calls += 1
      raise Integrations::Prodigi::Error.new(:throttled) if read_calls == 1
      JSON.generate(success_order_status_body)
    end
    read_adapter = sandbox_adapter(transport: read_transport, waiter: ->(_seconds) { })
    read_adapter.order_status(order_id: "ord_fixture_1")
    assert_equal 2, read_calls, "order_status must retry past a single throttled failure"

    order_calls = 0
    order_transport = fake_transport { |**| order_calls += 1; raise Integrations::Prodigi::Error.new(:throttled) }
    order_adapter = sandbox_adapter(transport: order_transport, waiter: ->(_seconds) { flunk "create_order retried" })
    assert_raises(Integrations::Prodigi::Error) { order_adapter.create_order(**VALID_ORDER_ARGS) }
    assert_equal 1, order_calls, "create_order must not retry the same failure a read would retry past"
  end

  test "create_order succeeds on the first attempt and is never retried when there is nothing to retry" do
    calls = 0
    transport = fake_transport { |**| calls += 1; JSON.generate(success_order_body) }
    adapter = sandbox_adapter(transport: transport, waiter: ->(_seconds) { flunk "no retry should ever be needed here" })

    result = adapter.create_order(**VALID_ORDER_ARGS)

    assert_equal 1, calls
    assert_equal "ord_fixture_1", result.dig("order", "id")
  end

  # -- raw_sink / observability --------------------------------------------

  test "sandbox mode invokes raw_sink with the operation, request, raw body, and observed_at on success" do
    captured = nil
    sink = ->(operation:, request:, body:, observed_at:) do
      captured = { operation: operation, request: request, body: body, observed_at: observed_at }
    end
    transport = fake_transport { |**| JSON.generate(success_product_body) }
    adapter = sandbox_adapter(transport: transport, raw_sink: sink)

    adapter.product(sku: "GLOBAL-CFPM-16X24")

    assert_equal :product, captured[:operation]
    assert_equal({ "sku" => "GLOBAL-CFPM-16X24" }, captured[:request])
    refute_nil captured[:body]
    refute_nil captured[:observed_at]
  end

  test "a failed sandbox call never invokes raw_sink" do
    sink = ->(**) { flunk "raw_sink must only see successful responses" }
    transport = fake_transport { |**| raise Integrations::Prodigi::Error.new(:validation_failed) }
    adapter = sandbox_adapter(transport: transport, raw_sink: sink)

    assert_raises(Integrations::Prodigi::Error) { adapter.product(sku: "GLOBAL-CFPM-16X24") }
  end

  # -- input validation ------------------------------------------------

  test "product rejects malformed or oversized sku input" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    [ nil, 1234, "", "x" * 201, "sku with space", "sku\nheader", "../secret" ].each do |sku|
      error = assert_raises(Integrations::Prodigi::Error) { adapter.product(sku: sku) }
      assert_equal :invalid_input, error.code
    end
  end

  test "order_status rejects malformed order_id input" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    [ nil, 1234, "", "id with space", "id\nheader" ].each do |id|
      error = assert_raises(Integrations::Prodigi::Error) { adapter.order_status(order_id: id) }
      assert_equal :invalid_input, error.code
    end
  end

  test "quote requires a well-formed destination_country and at least one item" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    [ "us", "USA", "US\n", nil, 1 ].each do |country|
      assert_raises(Integrations::Prodigi::Error) do
        adapter.quote(destination_country: country, items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1 } ])
      end
    end
    assert_raises(Integrations::Prodigi::Error) { adapter.quote(destination_country: "US", items: []) }
    assert_raises(Integrations::Prodigi::Error) { adapter.quote(destination_country: "US", items: [ { sku: "x", copies: 0 } ]) }
  end

  test "quote rejects a shipping_method outside the documented set" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    error = assert_raises(Integrations::Prodigi::Error) do
      adapter.quote(destination_country: "US", items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1 } ], shipping_method: "Teleport")
    end
    assert_equal :invalid_input, error.code
  end

  test "create_order requires every documented required field" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    [ :merchant_reference, :shipping_method, :recipient, :items, :idempotency_key ].each do |missing|
      args = VALID_ORDER_ARGS.reject { |key, _| key == missing }
      assert_raises(ArgumentError) { adapter.create_order(**args) }
    end
  end

  test "create_order rejects an unknown top-level field rather than silently accepting it" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    assert_raises(ArgumentError) { adapter.create_order(**VALID_ORDER_ARGS, some_unknown_field: "value") }
  end

  test "create_order rejects a malformed recipient" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    [ nil, "not-a-hash", {}, { name: "" }, { name: "Jane" } ].each do |bad_recipient|
      error = assert_raises(Integrations::Prodigi::Error) { adapter.create_order(**VALID_ORDER_ARGS, recipient: bad_recipient) }
      assert_equal :invalid_input, error.code
    end
  end

  test "create_order accepts an optional callback_url and metadata but validates their shape" do
    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture)
    assert_raises(Integrations::Prodigi::Error) { adapter.create_order(**VALID_ORDER_ARGS, callback_url: "not-a-url") }
    assert_raises(Integrations::Prodigi::Error) { adapter.create_order(**VALID_ORDER_ARGS, metadata: "not-a-hash") }
  end

  private

  def sandbox_adapter(transport:, pacer: no_op_pacer, waiter: ->(_seconds) { }, raw_sink: Integrations::Prodigi::Adapter::NO_RAW_SINK)
    Integrations::Prodigi::Adapter.new(
      mode: :sandbox, deployment: :development,
      capability: Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY,
      config: Integrations::Prodigi::Config.new(api_key: "synthetic-sandbox-key", mode: "sandbox"),
      transport: transport, pacer: pacer, waiter: waiter, raw_sink: raw_sink
    )
  end

  def no_op_pacer
    pacer = Object.new
    pacer.define_singleton_method(:throttle!) { }
    pacer
  end

  def fake_transport(&block)
    transport = Object.new
    transport.define_singleton_method(:call) do |operation:, api_key:, request:|
      block.call(operation: operation, api_key: api_key, request: request)
    end
    transport
  end

  def success_product_body
    { "outcome" => "Ok", "traceParent" => "fixture-trace-product-1",
      "product" => { "sku" => "GLOBAL-CFPM-16X24", "description" => "Framed canvas print" } }
  end

  def success_quote_body
    { "outcome" => "Created", "traceParent" => "fixture-trace-quote-1",
      "quotes" => [ { "shipmentMethod" => "Standard", "costSummary" => { "totalCost" => { "amount" => "17.34", "currency" => "USD" } } } ] }
  end

  def success_order_body
    { "outcome" => "Created", "traceParent" => "fixture-trace-order-1",
      "order" => { "id" => "ord_fixture_1", "status" => { "stage" => "InProgress" } } }
  end

  def success_order_status_body
    { "outcome" => "Ok", "traceParent" => "fixture-trace-order-status-1",
      "order" => { "id" => "ord_fixture_1", "status" => { "stage" => "Complete" } } }
  end
end
