require "test_helper"
require "json"
require "net/http"

# Boundary-layer contract for the second provider adapter: fixture mode must
# be fully deterministic, must never touch the network, and must never hand a
# caller a mutable shared payload. This phase has no Normalizer/Contracts
# layer yet (those need real captured Prodigi responses -- see
# .planning/prodigi-captures/ and the CJ precedent for why hand-written
# fixtures are not trusted as a field allowlist), so results are the raw
# parsed-and-frozen provider payload.
class ProdigiAdapterContractTest < ActiveSupport::TestCase
  ORDER_ARGS = {
    merchant_reference: "order-ref-1",
    shipping_method: "Standard",
    recipient: {
      name: "Jane Doe",
      address: { line1: "1 Main St", postalOrZipCode: "94103", countryCode: "US", townOrCity: "San Francisco" }
    },
    items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1, assets: [ { printArea: "default", url: "https://example.com/art.jpg" } ] } ],
    idempotency_key: "idem-key-1",
    callback_url: "https://example.com/callbacks/prodigi",
    metadata: { internalOrderId: "abc123" }
  }.freeze

  test "product is deterministic and returns a frozen, unmodifiable payload" do
    adapter = Integrations::Prodigi::Adapter.new
    first = adapter.product(sku: "GLOBAL-CFPM-16X24")
    second = adapter.product(sku: "GLOBAL-CFPM-16X24")

    assert_equal first, second
    assert_equal :fixture, adapter.mode
    assert first.frozen?
    assert_raises(FrozenError) { first["outcome"] = "changed" }
    assert_equal "GLOBAL-CFPM-16X24", first.dig("product", "sku")
  end

  test "quote is deterministic on an exact request match and returns a frozen payload" do
    adapter = Integrations::Prodigi::Adapter.new
    request = { destination_country: "US", shipping_method: "Standard", currency: "USD",
      items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1 } ] }

    first = adapter.quote(**request)
    second = adapter.quote(**request)

    assert_equal first, second
    assert_equal "Created", first.fetch("outcome")
    assert first.frozen?
  end

  test "create_order is deterministic on an exact request match and returns a frozen payload" do
    adapter = Integrations::Prodigi::Adapter.new
    first = adapter.create_order(**ORDER_ARGS)
    second = adapter.create_order(**ORDER_ARGS)

    assert_equal first, second
    assert_equal "ord_fixture_1", first.dig("order", "id")
    assert first.frozen?
  end

  test "order_status is deterministic and returns a frozen payload" do
    adapter = Integrations::Prodigi::Adapter.new
    first = adapter.order_status(order_id: "ord_fixture_1")
    second = adapter.order_status(order_id: "ord_fixture_1")

    assert_equal first, second
    assert_equal "ord_fixture_1", first.dig("order", "id")
    assert first.frozen?
  end

  test "a different request under the same operation is a distinct fixture_miss, never a stale match" do
    adapter = Integrations::Prodigi::Adapter.new
    assert_raises(Integrations::Prodigi::Error) { adapter.product(sku: "totally-unknown-sku") }
  end

  test "fixture mode never opens a socket, even when ambient environment claims sandbox" do
    previous = ENV["PRODIGI_MODE"]
    ENV["PRODIGI_MODE"] = "sandbox"
    never_call = ->(*_args, **_kwargs) { raise "Prodigi fixture mode attempted to open a socket" }
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*a, **k, &b| never_call.call(*a, **k, &b) }

    adapter = Integrations::Prodigi::Adapter.new
    adapter.product(sku: "GLOBAL-CFPM-16X24")
    adapter.quote(destination_country: "US", shipping_method: "Standard", currency: "USD",
      items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1 } ])
    adapter.order_status(order_id: "ord_fixture_1")
    adapter.create_order(**ORDER_ARGS)
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
    ENV["PRODIGI_MODE"] = previous
  end

  test "fixture mode never opens a socket even with a double that raises on any invocation" do
    exploding_http_client = Object.new
    exploding_http_client.define_singleton_method(:call) { |*_args, **_kwargs| raise "fixture mode must never reach a transport" }

    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture, transport: exploding_http_client)
    assert_nothing_raised { adapter.product(sku: "GLOBAL-CFPM-16X24") }
  end

  # This phase builds only the boundary/transport layer, with no
  # Normalizer/Contracts on top of it (those need real captured Prodigi
  # responses to derive an accurate field allowlist from -- see
  # .planning/prodigi-captures/ and the CJ precedent this repo already
  # learned that lesson from). So a malformed/throttled/unauthorized fixture
  # scenario is not yet interpreted into a typed Error: it is returned as the
  # raw, frozen envelope Prodigi's own "outcome"/"error" fields describe.
  # Turning that envelope into Integrations::Prodigi::Error(:throttled) etc.
  # is exactly what the later Normalizer phase is for.
  test "malformed, throttled, and unauthorized scenarios pass through as raw frozen envelopes" do
    malformed = Integrations::Prodigi::Adapter.new(scenario: :malformed).product(sku: "GLOBAL-CFPM-16X24")
    assert_equal "invalid payload shape", malformed["product"]
    assert malformed.frozen?

    throttled = Integrations::Prodigi::Adapter.new(scenario: :throttled).product(sku: "GLOBAL-CFPM-16X24")
    assert_equal "Error", throttled["outcome"]
    assert_equal "TooManyRequests", throttled.dig("error", "code")
    assert throttled.frozen?

    unauthorized = Integrations::Prodigi::Adapter.new(scenario: :unauthorized).product(sku: "GLOBAL-CFPM-16X24")
    assert_equal "Unauthorized", unauthorized.dig("error", "code")
    assert unauthorized.frozen?
  end

  test "committed fixture payloads never contain a live host or a credential-shaped field" do
    forbidden = /\A(?:apiKey|api_key|authorization|password|secret)\z/i
    inspect_keys = lambda do |value|
      case value
      when Hash
        value.each { |key, child| refute_match(forbidden, key.to_s); inspect_keys.call(child) }
      when Array
        value.each { |child| inspect_keys.call(child) }
      end
    end

    Dir[Rails.root.join("test/fixtures/files/prodigi/v1/*.json")].each do |path|
      contents = File.read(path)
      refute_match(/api\.prodigi\.com/, contents, "#{path} must never reference the live Prodigi host")
      inspect_keys.call(JSON.parse(contents))
    end
  end
end
