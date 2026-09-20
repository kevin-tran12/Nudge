require "test_helper"
require "json"
require "net/http"

class CjProductListTest < ActiveSupport::TestCase
  ModePolicy = Integrations::Cj::ModePolicy
  Governor = Integrations::Cj::Governor
  CjError = Integrations::Cj::Error

  FakeToken = Struct.new(:value)
  FakeAuthResult = Struct.new(:token)

  class FakeAuthentication
    def initialize(token_value: "synthetic-token")
      @token_value = token_value
    end

    def fetch
      FakeAuthResult.new(FakeToken.new(@token_value))
    end
  end

  class FakeTransport
    def initialize(&behavior)
      @behavior = behavior
      @calls = []
    end

    attr_reader :calls

    def call(operation:, token:, request:)
      @calls << { operation: operation, token: token, request: request }
      @behavior.call(@calls.size)
    end

    def authenticate(**)
      flunk "authenticate should not be reached by these fakes"
    end
  end

  class PoisonedTransport
    def call(**)
      raise "transport must not be invoked"
    end

    def authenticate(**)
      raise "transport must not be invoked"
    end
  end

  LIST_BODY = %({"code":200,"result":true,"data":{"total":1,"list":[{"pid":"00003006","productNameEn":"Leash","sellPrice":14.25}]}}).freeze

  # --- fixture mode -------------------------------------------------------

  test "fixture mode returns a normalized page and opens no socket" do
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "product_list attempted HTTP in fixture mode" }
    result = Integrations::Cj::Adapter.new.product_list(page: 1, page_size: 2, category: "pet-supplies")

    assert_instance_of Integrations::Cj::Contracts::ProductListPage, result.value
    assert_equal 1, result.value.page
    assert_equal 2, result.value.page_size
    assert_equal 5, result.value.total_count
    assert result.value.has_more
    assert_equal 2, result.value.products.size
    first = result.value.products.first
    assert_instance_of Integrations::Cj::Contracts::ProductSummary, first
    assert_equal "00003001", first.external_id
    assert_equal "FIXTURE-PETBOWL-2", first.sku
    assert_equal 1899, first.price.amount_minor
    assert_equal "https://cf.cjdropshipping.com/fixture/pet-bowl-2.jpg", first.image_url
    assert result.frozen?
    assert_raises(FrozenError) { result.value.products << first }
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  test "the last page reports no more results and an empty page is a valid observation" do
    result = Integrations::Cj::Adapter.new.product_list(page: 3, page_size: 2, category: "pet-supplies")
    refute result.value.has_more
    assert_equal 1, result.value.products.size

    empty = Integrations::Cj::Adapter.new.product_list(page: 1, page_size: 1, category: "empty-category")
    assert_equal 0, empty.value.total_count
    assert_empty empty.value.products
    refute empty.value.has_more
  end

  test "a keyword-only filter is supported without a category" do
    result = Integrations::Cj::Adapter.new.product_list(page: 1, page_size: 10, keyword: "leash")
    assert_equal 1, result.value.total_count
    assert_equal "Retractable dog leash", result.value.products.first.title
  end

  test "an unmatched request is a fixture miss rather than a silent empty page" do
    assert_raises(CjError) do
      Integrations::Cj::Adapter.new.product_list(page: 99, page_size: 2, category: "pet-supplies")
    end
  end

  # --- pagination and filter argument validation --------------------------

  test "page number must be a positive integer" do
    adapter = Integrations::Cj::Adapter.new
    [ 0, -1, 1.5, "1", nil ].each do |page|
      error = assert_raises(CjError) { adapter.product_list(page: page, page_size: 2, category: "pet-supplies") }
      assert_equal :invalid_input, error.code
    end
  end

  test "page size is bounded above and below" do
    adapter = Integrations::Cj::Adapter.new
    [ 0, -1, 1.5, "20", 201, 100_000 ].each do |page_size|
      error = assert_raises(CjError) { adapter.product_list(page: 1, page_size: page_size, category: "pet-supplies") }
      assert_equal :invalid_input, error.code
    end
  end

  test "at least one filter dimension is required" do
    adapter = Integrations::Cj::Adapter.new
    error = assert_raises(CjError) { adapter.product_list(page: 1, page_size: 2) }
    assert_equal :invalid_input, error.code
  end

  test "filter strings are length bounded and non-string input is rejected" do
    adapter = Integrations::Cj::Adapter.new
    bad_encoding = "\xFF".dup.force_encoding("UTF-8")
    [ 123, [], {}, "x" * 101, "bad\nvalue", bad_encoding ].each do |value|
      error = assert_raises(CjError) { adapter.product_list(page: 1, page_size: 2, category: value) }
      assert_equal :invalid_input, error.code
      error = assert_raises(CjError) { adapter.product_list(page: 1, page_size: 2, keyword: value) }
      assert_equal :invalid_input, error.code
    end
  end

  # --- normalization / fail-closed behavior -------------------------------

  test "a malformed, oversized, or wrong-shaped response fails closed with a typed error" do
    [
      { "code" => 200, "result" => true, "data" => "not a hash" },
      { "code" => 200, "result" => true, "data" => { "total" => 1 } },
      { "code" => 200, "result" => true, "data" => { "list" => [] } },
      { "code" => 200, "result" => true, "data" => { "total" => -1, "list" => [] } },
      { "code" => 200, "result" => true, "data" => { "total" => 1, "list" => "not an array" } },
      { "code" => 200, "result" => true, "data" => { "total" => 1, "list" => [ { "productNameEn" => "No pid" } ] } },
      { "code" => 200, "result" => true, "data" => { "total" => 1, "list" => [ "not a hash" ] } },
    ].each do |body|
      error = assert_raises(CjError) { normalize(body) }
      assert_equal :malformed_response, error.code
    end

    oversized = { "code" => 200, "result" => true,
      "data" => { "total" => 500, "list" => Array.new(201) { { "pid" => "00000001", "productNameEn" => "x" } } } }
    error = assert_raises(CjError) { normalize(oversized) }
    assert_equal :malformed_response, error.code

    duplicate = { "code" => 200, "result" => true, "data" => { "total" => 2,
      "list" => [ { "pid" => "00000001", "productNameEn" => "a" }, { "pid" => "00000001", "productNameEn" => "b" } ] } }
    error = assert_raises(CjError) { normalize(duplicate) }
    assert_equal :malformed_response, error.code
  end

  test "supplier text containing prompt-injection style content is returned inert" do
    result = Integrations::Cj::Adapter.new.product_list(page: 1, page_size: 2, category: "pet-supplies")
    injected = result.value.products.find { |p| p.external_id == "00003002" }
    refute_nil injected
    assert_includes injected.title, "Cat scratching post"
    refute injected.title.html_safe?
  end

  test "a media URL on a non-approved host is rejected" do
    [ "http://cf.cjdropshipping.com/a.jpg", "https://evil.example/a.jpg",
      "https://cf.cjdropshipping.com.evil.example/a.jpg", "javascript:alert(1)" ].each do |url|
      body = { "code" => 200, "result" => true,
        "data" => { "total" => 1, "list" => [ { "pid" => "00000001", "productNameEn" => "x", "productImage" => url } ] } }
      error = assert_raises(CjError) { normalize(body) }
      assert_equal :unsafe_url, error.code
    end
  end

  test "no raw provider structure escapes the adapter boundary" do
    result = Integrations::Cj::Adapter.new.product_list(page: 1, page_size: 2, category: "pet-supplies")
    refute_kind_of Hash, result.value
    result.value.products.each { |summary| refute_kind_of Hash, summary }
    assert_instance_of Integrations::Cj::Contracts::Result, result
  end

  # --- points budget and rate governor ------------------------------------

  test "points budget exhaustion prevents the request from being attempted" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 10) # catalog partition = 6, product_list costs 50
    transport = FakeTransport.new { flunk "governor exhaustion must prevent a transport call" }
    adapter = build_adapter(policy: policy, governor: governor, transport: transport)

    error = assert_raises(CjError) { adapter.product_list(page: 1, page_size: 2, category: "pet-supplies") }

    assert_equal :quota_exhausted, error.code
    assert_empty transport.calls
  end

  test "rate governor refusal prevents the request from being attempted" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { 0 })
    governor.admit!(purpose: :catalog, points: 1)
    transport = FakeTransport.new { flunk "throttled admission must prevent a transport call" }
    adapter = build_adapter(policy: policy, governor: governor, transport: transport)

    error = assert_raises(CjError) { adapter.product_list(page: 1, page_size: 2, category: "pet-supplies") }
    assert_equal :throttled, error.code
    assert_empty transport.calls
  end

  test "a live response is admitted at the documented 50-point catalog cost and normalized" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { 0 })
    transport = FakeTransport.new { LIST_BODY }
    adapter = build_adapter(policy: policy, governor: governor, transport: transport)

    result = adapter.product_list(page: 1, page_size: 10, keyword: "leash")

    assert_equal 1, transport.calls.size
    assert_instance_of Integrations::Cj::Contracts::ProductListPage, result.value
    expected_catalog = (500 * 60 / 100) - Integrations::Cj::Adapter::POINTS.fetch(:product_list)
    assert_equal({ catalog: expected_catalog, critical: 500 * 30 / 100, recovery: 500 * 10 / 100 }, governor.remaining)
  end

  # --- mode capability ------------------------------------------------------

  test "a non-fixture mode is refused without the explicit capability" do
    [ :verify, :record ].each do |mode|
      error = assert_raises(CjError) { Integrations::Cj::Adapter.new(mode: mode, deployment: :development) }
      assert_equal :unsupported_mode, error.code
    end
    error = assert_raises(CjError) { Integrations::Cj::Adapter.new(mode: :live, deployment: :production) }
    assert_equal :unsupported_mode, error.code
  end

  test "the transport is never constructed or invoked in fixture mode even if one is supplied" do
    adapter = Integrations::Cj::Adapter.new(transport: PoisonedTransport.new, governor: :unused, authentication: :unused)
    result = adapter.product_list(page: 1, page_size: 2, category: "pet-supplies")
    assert_equal :fixture, adapter.mode
    assert_instance_of Integrations::Cj::Contracts::ProductListPage, result.value
  end

  private
    def build_adapter(policy:, governor:, transport:, waiter: ->(_seconds) { })
      Integrations::Cj::Adapter.new(mode: policy.mode, deployment: :development, capability: ModePolicy::VERIFY_CAPABILITY,
        config: Integrations::Cj::Config.new(api_key: "synthetic-key"), governor: governor, transport: transport,
        authentication: FakeAuthentication.new, waiter: waiter)
    end

    def normalize(body)
      Integrations::Cj::Normalizer.new.call(operation: :product_list, body: JSON.generate(body),
        request: { "pageNum" => 1, "pageSize" => 2, "categoryId" => "pet-supplies", "keyword" => nil },
        observed_at: "2026-09-20T00:00:00Z")
    end
end
