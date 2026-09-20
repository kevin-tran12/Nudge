require "test_helper"
require "json"
require "net/http"
require "stringio"

class CjAdapterContractTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files/cj/v1")

  test "fixture default is deterministic and preserves opaque identities and exact money" do
    adapter = Integrations::Cj::Adapter.new
    result = adapter.product(product_id: "00001234")
    assert_equal result, adapter.product(product_id: "00001234")
    assert_equal :fixture, adapter.mode
    assert_instance_of Integrations::Cj::Contracts::Product, result.value
    assert_equal "00001234", result.value.external_id
    variant = result.value.variants.first
    assert_equal "00005678", variant.external_id
    assert_equal "FIXTURE-BIN-S", variant.sku
    assert_equal 1234, variant.price.amount_minor
    assert_equal "USD", variant.price.currency
    assert_equal BigDecimal("250.5"), variant.weight.value
    assert_equal "g", variant.weight.unit
    assert_equal "mm", variant.length.unit
    assert_nil result.value.variants.last.price
    assert_nil result.value.variants.last.weight
    assert_nil result.value.variants.last.length
    assert_equal :synthetic_fixture, result.provenance.source
    assert_equal Time.iso8601("2026-09-20T00:00:00Z"), result.provenance.observed_at
    assert_equal "1", result.provenance.payload_version
    assert_match(/\A[0-9a-f]{64}\z/, result.provenance.payload_sha256)
    assert_raises(FrozenError) { result.value.variants << variant }
    assert_raises(FrozenError) { variant.external_id.replace("changed") }
  end

  test "inventory remains warehouse scoped with distinct subwarehouse references and unknown quantities" do
    result = Integrations::Cj::Adapter.new.inventory(variant_id: "00005678")
    assert_equal [ "01", "02" ], result.value.map(&:warehouse_id)
    first, second = result.value
    assert_equal "00005678", first.variant_id
    assert_equal "CN", first.country_code
    assert_equal [ 9, 4, 5 ], [ first.total_quantity, first.cj_quantity, first.factory_quantity ]
    assert_equal "{fixture-stock-1}", first.subwarehouses.first.external_id
    assert_equal 0, second.total_quantity
    assert_nil second.factory_quantity
    assert_nil second.subwarehouses
  end

  test "freight is an exact request fixture estimate and never implies route eligibility or expiry" do
    result = Integrations::Cj::Adapter.new.freight(**freight_request)
    quote = result.value.first
    assert_equal 471, quote.price.amount_minor
    assert_equal "Fixture carrier", quote.service_name
    assert_equal "7-12", quote.delivery_estimate
    assert_equal :unknown, quote.eligibility
    assert_equal :estimate, quote.kind
    assert_nil quote.expires_at
    assert_nil quote.total_price
    assert_nil quote.tax
    assert_nil quote.clearance_fee
    assert_equal "CN", result.request.fetch("origin_country")
    assert_equal 1, result.request.fetch("items").first.fetch("quantity")
    assert_raises(FrozenError) { result.request.fetch("items").first["quantity"] = 2 }
    assert_error(:fixture_miss) { Integrations::Cj::Adapter.new.freight(**freight_request.merge(destination_country: "GB")) }
    assert_error(:fixture_miss) { Integrations::Cj::Adapter.new.product(product_id: "different-product") }
  end

  test "all nonfixture modes and unknown fixture scenarios fail closed" do
    [ :verify, :record, :live, :unknown, nil, "FIXTURE" ].each do |mode|
      assert_error(:unsupported_mode) { Integrations::Cj::Adapter.new(mode: mode) }
    end
    assert_error(:invalid_input) { Integrations::Cj::Adapter.new(scenario: "../../anything") }
    assert_equal :fixture, Integrations::Cj::Adapter.new(mode: "fixture").mode
  end

  test "fixture mode performs no network call or database query and ignores ambient live mode" do
    previous = ENV["CJ_MODE"]
    ENV["CJ_MODE"] = "live"
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*event| queries << event }
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "CJ fixture attempted HTTP" }
    Integrations::Cj::Adapter.new.product(product_id: "00001234")
    Integrations::Cj::Adapter.new.inventory(variant_id: "00005678")
    Integrations::Cj::Adapter.new.freight(**freight_request)
    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Net::HTTP.define_singleton_method(:start, original) if original
    ENV["CJ_MODE"] = previous
  end

  test "input types and sizes are bounded without coercing identifiers or quantities" do
    adapter = Integrations::Cj::Adapter.new
    [ nil, 1234, "", "x" * 201, "../secret", "id\nheader", "\xFF".dup.force_encoding("UTF-8") ].each do |id|
      assert_error(:invalid_input) { adapter.product(product_id: id) }
      assert_error(:invalid_input) { adapter.inventory(variant_id: id) }
    end
    [ "us", "USA", "US\n", 1, "\xFF".dup.force_encoding("UTF-8") ].each do |country|
      assert_error(:invalid_input) { adapter.freight(**freight_request.merge(destination_country: country)) }
    end
    [ 0, -1, 1.1, "1", 10_001 ].each do |quantity|
      assert_error(:invalid_input) { adapter.freight(**freight_request.merge(items: [ { variant_id: "00005678", quantity: quantity } ])) }
    end
    [ [], Array.new(101) { { variant_id: "00005678", quantity: 1 } }, [ {} ], [ "bad" ],
      [ { variant_id: "00005678", "quantity" => 1 } ], Array.new(2) { { variant_id: "00005678", quantity: 1 } } ].each do |items|
      assert_error(:invalid_input) { adapter.freight(**freight_request.merge(items: items)) }
    end
  end

  test "inventory supports documented numeric area IDs without changing caller inputs" do
    id = +"00005678"
    Integrations::Cj::Adapter.new.inventory(variant_id: id)
    refute id.frozen?
    body = JSON.parse(FIXTURES.join("inventory.json").read).fetch("response")
    body["data"][0]["areaId"] = 1
    result = Integrations::Cj::Normalizer.new.call(operation: :inventory, body: JSON.generate(body),
      request: { "variant_id" => id }, observed_at: "2026-09-20T00:00:00Z")
    assert_equal "1", result.value.first.warehouse_id
  end

  test "malformed fixture data never becomes a partial successful result" do
    adapter = Integrations::Cj::Adapter.new(scenario: :malformed)
    assert_error(:malformed_response) { adapter.product(product_id: "00001234") }
    assert_error(:malformed_response) { adapter.inventory(variant_id: "00005678") }
    assert_error(:malformed_response) { adapter.freight(**freight_request) }
  end

  test "throttle and auth errors classify recovery without retrying" do
    error = assert_error(:throttled) { Integrations::Cj::Adapter.new(scenario: :throttled).product(product_id: "00001234") }
    assert_equal :backoff, error.retry_strategy
    assert error.retryable?
    error = assert_error(:authentication_failed) { Integrations::Cj::Adapter.new(scenario: :expired_auth).product(product_id: "00001234") }
    assert_equal :pause, error.retry_strategy
    refute error.retryable?
  end

  test "provider codes distinguish unavailable quota validation not found and unknown errors" do
    { 1600000 => [ :unavailable, :backoff ], 1600301 => [ :unavailable, :backoff ],
      1600201 => [ :quota_exhausted, :pause ], 1600300 => [ :provider_rejected, :never ],
      1602001 => [ :not_found, :never ], 9999999 => [ :provider_rejected, :never ] }.each do |code, expected|
      body = { "code" => code, "result" => false, "data" => nil }
      error = assert_error(expected.first) { normalize(body) }
      assert_equal expected.last, error.retry_strategy
    end
  end

  test "invalid envelopes nested payloads identity mismatches duplicates and numeric corruption fail closed" do
    [ nil, [], {}, { "code" => "200", "result" => true }, { "code" => 200, "result" => "true" } ].each do |body|
      assert_error(:malformed_response) { normalize(body) }
    end
    [ -1, "NaN", "1.001", "1e100", true ].each do |price|
      body = product_body
      body["data"]["variants"][0]["variantSellPrice"] = price
      assert_error(:malformed_response) { normalize(body) }
    end
    body = product_body
    body["data"]["pid"] = "wrong"
    assert_error(:malformed_response) { normalize(body) }
    body = product_body
    body["data"]["variants"] << body["data"]["variants"].first
    assert_error(:malformed_response) { normalize(body) }
    assert_error(:malformed_response) { normalize_raw("[" * 30 + "]" * 30) }
    assert_error(:malformed_response) { normalize_raw(" " * 262_145) }
  end

  test "untrusted media URLs are never accepted as fetch targets" do
    [ "http://cf.cjdropshipping.com/a.jpg", "https://127.0.0.1/a", "https://[::1]/a", "https://localhost/a",
      "https://cf.cjdropshipping.com.evil.example/a", "https://user:password@cf.cjdropshipping.com/a",
      "https://cf.cjdropshipping.com:444/a", "https://cf.cjdropshipping.com/a?token=synthetic",
      "https://cf.cjdropshipping.com/a#secret", "https://cf.cjdropshipping.com/%2e%2e/a", "javascript:alert(1)" ].each do |url|
      body = product_body
      body["data"]["productImageSet"] = [ url ]
      assert_error(:unsafe_url) { normalize(body) }
    end
  end

  test "HTML is reduced to plain untrusted text and unknown secret fields never escape" do
    body = product_body
    body["data"]["description"] = '<p>Safe</p><script>alert("SYNTHETIC-SECRET")</script><img src=x onerror=alert(1)>'
    body["data"]["accessToken"] = "SYNTHETIC-SECRET"
    result = normalize(body)
    assert_equal "Safe", result.value.description
    refute result.value.description.html_safe?
    refute_includes result.inspect, "SYNTHETIC-SECRET"
  end

  test "exceptions and logs exclude supplier messages bodies and parser causes" do
    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    [ '{"SYNTHETIC-SECRET":', JSON.generate("code" => 1600001, "result" => false, "message" => "SYNTHETIC-SECRET") ].each do |body|
      error = assert_raises(Integrations::Cj::Error) { normalize_raw(body) }
      refute_includes error.full_message, "SYNTHETIC-SECRET"
      assert_nil error.cause
    end
    assert_empty log.string
  ensure
    Rails.logger = previous_logger
  end

  test "supplier SKU references retain their exact text while labels remain plain strings" do
    body = product_body
    body["data"]["productSku"] = "BIN<SMALL>"
    body["data"]["variants"][0]["variantSku"] = "BIN<SMALL>-1"
    result = normalize(body)
    assert_equal "BIN<SMALL>", result.value.sku
    assert_equal "BIN<SMALL>-1", result.value.variants.first.sku
    refute result.value.sku.html_safe?
  end

  test "inventory corruption does not become missing or zero stock" do
    base = JSON.parse(FIXTURES.join("inventory.json").read).fetch("response")
    [ -1, "9", 1.5 ].each do |quantity|
      body = base.deep_dup
      body["data"][0]["totalInventoryNum"] = quantity
      assert_error(:malformed_response) { normalize_operation(:inventory, body, "variant_id" => "00005678") }
    end
    base["data"] << base["data"].first
    assert_error(:malformed_response) { normalize_operation(:inventory, base, "variant_id" => "00005678") }
  end

  test "empty inventory and freight remain empty observations and oversized lists are rejected" do
    body = { "code" => 200, "result" => true, "data" => [] }
    assert_empty normalize_operation(:inventory, body, "variant_id" => "00005678").value
    assert_empty normalize_operation(:freight, body, {}).value
    body["data"] = Array.new(101, {})
    assert_error(:malformed_response) { normalize_operation(:inventory, body, "variant_id" => "00005678") }
    assert_error(:malformed_response) { normalize_operation(:freight, body, {}) }
    assert_error(:malformed_response) { normalize_raw(JSON.generate(product_body).sub("12.34", "1e10000")) }
    assert_error(:malformed_response) { normalize_raw(JSON.generate(product_body).sub("250.5", "1e-10000")) }
  end

  test "committed fixture payloads contain no credential or customer fields" do
    forbidden = /\A(?:accessToken|refreshToken|openId|authorization|sign|apiKey|email|phone|recipientName|address|zip)\z/i
    inspect_keys = lambda do |value|
      case value
      when Hash
        value.each { |key, child| refute_match(forbidden, key); inspect_keys.call(child) }
      when Array
        value.each { |child| inspect_keys.call(child) }
      end
    end
    Dir[FIXTURES.join("*.json")].each { |path| inspect_keys.call(JSON.parse(File.read(path))) }
  end

  private
    def freight_request
      { origin_country: "CN", destination_country: "US", items: [ { variant_id: "00005678", quantity: 1 } ] }
    end

    def product_body
      JSON.parse(FIXTURES.join("product.json").read).fetch("response")
    end

    def normalize(body)
      normalize_raw(JSON.generate(body))
    end

    def normalize_operation(operation, body, request)
      Integrations::Cj::Normalizer.new.call(operation: operation, body: JSON.generate(body),
        request: request, observed_at: "2026-09-20T00:00:00Z")
    end

    def normalize_raw(body)
      Integrations::Cj::Normalizer.new.call(operation: :product, body: body,
        request: { "product_id" => "00001234" }, observed_at: "2026-09-20T00:00:00Z")
    end

    def assert_error(code, &block)
      error = assert_raises(Integrations::Cj::Error, &block)
      assert_equal code, error.code
      error
    end
end
