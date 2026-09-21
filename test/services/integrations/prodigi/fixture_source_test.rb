require "test_helper"
require "json"

class ProdigiFixtureSourceTest < ActiveSupport::TestCase
  test "an exact matching request returns the recorded response body and observed_at" do
    source = Integrations::Prodigi::FixtureSource.new(scenario: :success)
    fixture = source.read(:product, { "sku" => "GLOBAL-CFPM-16X24" })

    body = JSON.parse(fixture.fetch(:body))
    assert_equal "Ok", body.fetch("outcome")
    assert_equal "GLOBAL-CFPM-16X24", body.dig("product", "sku")
    assert_equal "2026-09-20T00:00:00Z", fixture.fetch(:observed_at)
  end

  test "a request that does not exactly match any recorded entry is a fixture_miss" do
    source = Integrations::Prodigi::FixtureSource.new(scenario: :success)
    error = assert_raises(Integrations::Prodigi::Error) { source.read(:product, { "sku" => "does-not-exist" }) }
    assert_equal :fixture_miss, error.code
  end

  test "an unknown operation is rejected before any file is read" do
    source = Integrations::Prodigi::FixtureSource.new(scenario: :success)
    error = assert_raises(Integrations::Prodigi::Error) { source.read(:not_a_real_operation, {}) }
    assert_equal :invalid_input, error.code
  end

  test "an unknown scenario is rejected at construction, never as a file path" do
    [ "../../etc/passwd", "unknown", nil, 1, :bogus ].each do |scenario|
      error = assert_raises(Integrations::Prodigi::Error) { Integrations::Prodigi::FixtureSource.new(scenario: scenario) }
      assert_equal :invalid_input, error.code
    end
  end

  test "every documented operation and scenario is present" do
    assert_equal %i[product quote order order_status], Integrations::Prodigi::FixtureSource::OPERATIONS
    assert_equal %i[success throttled unauthorized malformed], Integrations::Prodigi::FixtureSource::SCENARIOS
    assert Integrations::Prodigi::FixtureSource::OPERATIONS.frozen?
    assert Integrations::Prodigi::FixtureSource::SCENARIOS.frozen?
  end

  test "non-success scenarios read the scenario-wide file regardless of which entry matched" do
    [ :throttled, :unauthorized, :malformed ].each do |scenario|
      source = Integrations::Prodigi::FixtureSource.new(scenario: scenario)
      fixture = source.read(:product, { "sku" => "GLOBAL-CFPM-16X24" })
      body = JSON.parse(fixture.fetch(:body))
      refute_equal "GLOBAL-CFPM-16X24", body.dig("product", "sku")
    end
  end

  test "a non-success scenario still requires the request to match a recorded entry first" do
    source = Integrations::Prodigi::FixtureSource.new(scenario: :throttled)
    error = assert_raises(Integrations::Prodigi::Error) { source.read(:product, { "sku" => "does-not-exist" }) }
    assert_equal :fixture_miss, error.code
  end

  test "quote, order, and order_status each resolve their own fixture file" do
    source = Integrations::Prodigi::FixtureSource.new(scenario: :success)

    quote_request = {
      "destination_country" => "US", "shipping_method" => "Standard", "currency" => "USD",
      "items" => [ { "sku" => "GLOBAL-CFPM-16X24", "copies" => 1 } ]
    }
    quote_fixture = source.read(:quote, quote_request)
    assert_equal "Created", JSON.parse(quote_fixture.fetch(:body)).fetch("outcome")

    order_status_fixture = source.read(:order_status, { "order_id" => "ord_fixture_1" })
    assert_equal "ord_fixture_1", JSON.parse(order_status_fixture.fetch(:body)).dig("order", "id")
  end

  test "every committed prodigi fixture file declares the current fixture_version" do
    Dir[Rails.root.join("test/fixtures/files/prodigi/v1/{product,quote,order,order_status}.json")].each do |path|
      data = JSON.parse(File.read(path))
      assert_equal Integrations::Prodigi::FixtureSource::FIXTURE_VERSION, data.fetch("fixture_version"), path
    end
  end

  test "a stale or missing fixture_version fails closed as malformed_response" do
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      root.join("product.json").write(JSON.generate(
        "fixture_version" => 999, "observed_at" => "2026-09-20T00:00:00Z",
        "entries" => [ { "request" => { "sku" => "x" }, "response" => {} } ]
      ))

      stub_root(root) do
        source = Integrations::Prodigi::FixtureSource.new(scenario: :success)
        error = assert_raises(Integrations::Prodigi::Error) { source.read(:product, { "sku" => "x" }) }
        assert_equal :malformed_response, error.code
      end
    end
  end

  private
    # ROOT is a frozen class constant, so this stubs the constant for the
    # duration of the block rather than mutating shared fixture files.
    def stub_root(root)
      original = Integrations::Prodigi::FixtureSource::ROOT
      Integrations::Prodigi::FixtureSource.send(:remove_const, :ROOT)
      Integrations::Prodigi::FixtureSource.const_set(:ROOT, root)
      yield
    ensure
      Integrations::Prodigi::FixtureSource.send(:remove_const, :ROOT)
      Integrations::Prodigi::FixtureSource.const_set(:ROOT, original)
    end
end
