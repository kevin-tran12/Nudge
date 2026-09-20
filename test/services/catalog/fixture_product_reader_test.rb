require "test_helper"
require "net/http"

class FixtureProductReaderTest < ActiveSupport::TestCase
  test "lists and reads deterministic provider-neutral catalog projections" do
    reader = Catalog::FixtureProductReader.new

    first_page = reader.list(limit: 1)
    assert_equal first_page, reader.list(limit: 1)
    assert_equal 1, first_page.items.length
    assert_nil first_page.next_cursor

    product = first_page.items.first
    assert_equal product, reader.detail(id: product.id)
    assert_equal "00001234", product.id
    assert_equal "Stacking storage bin", product.title
    assert_equal "A reusable storage bin.", product.description
    assert_equal :known, product.images_state
    assert_equal [ "https://cf.cjdropshipping.com/fixture/storage-bin.jpg" ], product.images.map(&:url)
    assert_equal [ "00005678", "fixture-variant-unknown" ], product.variants.map(&:id)
    assert_equal Time.iso8601("2026-09-20T00:00:00Z"), product.freshness.observed_at
    assert_equal :observed, product.freshness.state

    known, unknown = product.variants
    assert_equal [ :known, 1234, "USD" ], [ known.price.state, known.price.amount_minor, known.price.currency ]
    assert_equal [ :available, 9, :observed ], [ known.availability.state, known.availability.quantity, known.availability.reason ]
    assert_equal [ :known, BigDecimal("250.5"), "g" ], [ known.weight.state, known.weight.value, known.weight.unit ]
    assert_equal :unknown, unknown.price.state
    assert_nil unknown.price.amount_minor
    assert_equal :unknown, unknown.availability.state
    assert_equal :not_observed, unknown.availability.reason
    assert_equal :unknown, unknown.weight.state

    assert_no_provider_contracts(product)
  end

  test "outputs and nested values are immutable and supplier text remains plain" do
    product = Catalog::FixtureProductReader.new.detail(id: "00001234")

    refute product.title.html_safe?
    refute product.description.html_safe?
    refute_includes product.description, "<"
    assert_raises(FrozenError) { product.title.replace("changed") }
    assert_raises(FrozenError) { product.images << product.images.first }
    assert_raises(FrozenError) { product.variants.first.price.currency.replace("EUR") }

    result = Integrations::Cj::Adapter.new.product(product_id: "00001234")
    native_reference = result.with(value: result.value.with(sku: ActiveSupport::SafeBuffer.new("BIN<SMALL>")))
    projected = Catalog::FixtureProductReader.new(
      adapter: StubAdapter.new(product_result: native_reference)
    ).detail(id: "00001234")
    assert_equal "BIN<SMALL>", projected.sku
    assert_instance_of String, projected.sku
    refute projected.sku.html_safe?
    assert_raises(FrozenError) { projected.sku.replace("changed") }
  end

  test "pagination inputs are bounded and ordering is stable" do
    reader = Catalog::FixtureProductReader.new

    [ 0, -1, 25, "1", nil ].each do |limit|
      assert_catalog_error(:invalid_input) { reader.list(limit: limit) }
    end
    [ "", "-1", "01", "1.0", "x", 0, "9" ].each do |cursor|
      assert_catalog_error(:invalid_input) { reader.list(cursor: cursor) }
    end
    [ nil, "", 1, "../00001234", "x" * 201 ].each do |id|
      assert_catalog_error(:invalid_input) { reader.detail(id: id) }
    end

    assert_catalog_error(:not_found) { reader.detail(id: "unknown-product") }
    assert_equal [ "00001234" ], reader.list(limit: 24, cursor: "0").items.map(&:id)

    first = Integrations::Cj::Adapter.new.product(product_id: "00001234")
    second_variants = first.value.variants.map.with_index do |variant, index|
      variant.with(external_id: "fixture-second-#{index}", product_id: "00009999")
    end
    second = first.with(value: first.value.with(external_id: "00009999", variants: second_variants))
    paged = Catalog::FixtureProductReader.new(
      adapter: StubAdapter.new(product_results: { "00001234" => first, "00009999" => second }),
      product_ids: [ "00009999", "00001234" ]
    )

    page_one = paged.list(limit: 1)
    assert_equal [ "00001234" ], page_one.items.map(&:id)
    assert_equal "1", page_one.next_cursor
    page_two = paged.list(limit: 1, cursor: page_one.next_cursor)
    assert_equal [ "00009999" ], page_two.items.map(&:id)
    assert_nil page_two.next_cursor
  end

  test "malformed products fail closed without partial output" do
    reader = Catalog::FixtureProductReader.new(adapter: Integrations::Cj::Adapter.new(scenario: :malformed))

    error = assert_catalog_error(:source_unavailable) { reader.list }
    refute error.retryable?
    assert_catalog_error(:source_unavailable) { reader.detail(id: "00001234") }
  end

  test "missing or broken inventory remains explicitly unknown" do
    product_result = Integrations::Cj::Adapter.new.product(product_id: "00001234")
    adapter = StubAdapter.new(product_result: product_result, inventory_error: :malformed_response)

    product = Catalog::FixtureProductReader.new(adapter: adapter).detail(id: "00001234")

    product.variants.each do |variant|
      assert_equal :unknown, variant.availability.state
      assert_equal :source_error, variant.availability.reason
      assert_nil variant.availability.quantity
      assert_equal :unknown, variant.availability.freshness.state
    end
  end

  test "unsafe media references are rejected at the catalog boundary" do
    product_result = Integrations::Cj::Adapter.new.product(product_id: "00001234")
    unsafe_urls = [
      "javascript:alert(1)",
      "https://localhost./a.jpg",
      "https://127.1/a.jpg",
      "https://127.0.0.1./a.jpg",
      "https://0x7f.0.0.1/a.jpg",
      "https://%31%32%37.0.0.1/a.jpg",
      "https://cf.cjdropshipping.com./a.jpg",
      "https://example.com/a.jpg"
    ]

    unsafe_urls.each do |url|
      unsafe_product = product_result.value.with(image_urls: [ url ])
      unsafe_result = product_result.with(value: unsafe_product)
      reader = Catalog::FixtureProductReader.new(adapter: StubAdapter.new(product_result: unsafe_result))

      assert_catalog_error(:source_unavailable) { reader.detail(id: "00001234") }
    end
  end

  test "invalid identifier and cursor encodings fail with stable input errors" do
    reader = Catalog::FixtureProductReader.new
    invalid_utf8 = "\xFF".dup.force_encoding(Encoding::UTF_8)
    utf16_identifier = "00001234".encode(Encoding::UTF_16LE)
    utf16_cursor = "1".encode(Encoding::UTF_16LE)

    [ invalid_utf8, utf16_identifier ].each do |id|
      error = assert_catalog_error(:invalid_input) { reader.detail(id: id) }
      assert_nil error.cause
    end
    [ invalid_utf8, utf16_cursor ].each do |cursor|
      error = assert_catalog_error(:invalid_input) { reader.list(cursor: cursor) }
      assert_nil error.cause
    end
  end

  test "catalog reads make no network calls or database queries" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*event| queries << event }
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "catalog reader attempted HTTP" }

    reader = Catalog::FixtureProductReader.new
    reader.list
    reader.detail(id: "00001234")

    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  private
    class StubAdapter
      def initialize(product_result: nil, product_results: nil, inventory_error: :fixture_miss)
        @product_results = product_results || { product_result.value.external_id => product_result }
        @inventory_error = inventory_error
      end

      def product(product_id:)
        @product_results.fetch(product_id)
      end

      def inventory(variant_id:)
        raise Integrations::Cj::Error.new(@inventory_error)
      end
    end

    def assert_catalog_error(code, &block)
      error = assert_raises(Catalog::ProductReader::Error, &block)
      assert_equal code, error.code
      error
    end

    def assert_no_provider_contracts(value)
      case value
      when Data
        refute value.class.name.start_with?("Integrations::")
        value.to_h.each_value { |child| assert_no_provider_contracts(child) }
      when Array
        value.each { |child| assert_no_provider_contracts(child) }
      end
    end
end
