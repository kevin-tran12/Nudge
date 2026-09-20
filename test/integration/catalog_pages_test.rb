require "test_helper"

class CatalogPagesTest < ActionDispatch::IntegrationTest
  test "public index and detail render clearly labelled fixture projections without supplier media" do
    get products_path

    assert_response :success
    assert_select "h1", text: "Browse the sample catalog"
    assert_select "[data-catalog-disclosure]", text: /illustrative/i
    assert_select "article", count: 1
    assert_select "a[href='#{product_path('00001234')}']", text: "Stacking storage bin"
    assert_select "[role='img'][data-local-placeholder]"
    assert_select "img", count: 0
    assert_select "[src*='cjdropshipping'], [srcset*='cjdropshipping'], [style*='cjdropshipping']", count: 0
    refute_includes response.body, "cf.cjdropshipping.com"
    assert_select "time[datetime='2026-09-20T00:00:00Z']"

    get product_path("00001234")

    assert_response :success
    assert_select "h1", text: "Stacking storage bin"
    assert_select "[data-price-state='known']", text: /Illustrative price: USD 12\.34/
    assert_select "[data-price-state='unknown']", text: /Illustrative price unavailable/
    assert_select "[data-availability-state='available']", text: /9 units observed/
    assert_select "[data-availability-state='unknown']", text: /Availability unknown/
    assert_select "[data-inventory-disclaimer]", text: /not reserved.*eligibility.*guaranteed/i
    assert_select "img", count: 0
    refute_includes response.body, "cf.cjdropshipping.com"
  end

  test "supplier text is escaped and opaque media references never become fetch attributes" do
    product = catalog_product(
      title: '<script data-secret="supplier-title">bad()</script>Safe & useful',
      description: '<img data-secret="supplier-description">Description & details',
      images: [ Catalog::ProductReader::Image.new(url: "https://supplier.example/private.jpg", position: 0) ]
    )
    with_reader(StaticReader.new(page: catalog_page(product), product:)) do
      get product_path(product.id)
    end

    assert_response :success
    assert_select "script[data-secret]", count: 0
    assert_select "img", count: 0
    Nokogiri::HTML(response.body).css("[src], [srcset], [style], link[href]").each do |element|
      refute_match(/supplier\.example/, element.to_s)
    end
    assert_includes response.body, "&lt;script"
    assert_includes response.body, "Safe &amp; useful"
    refute_includes response.body, "private.jpg"
    assert_includes response.body, "&lt;img"
  end

  test "index uses a fixed bound and forwards a scalar cursor without interpreting it" do
    reader = StaticReader.new(page: Catalog::ProductReader::Page.new(items: [], next_cursor: nil))
    with_reader(reader) { get products_path(cursor: "opaque-cursor-value") }

    assert_response :success
    assert_equal [ { limit: ProductsController::PAGE_SIZE, cursor: "opaque-cursor-value" } ], reader.list_calls
    assert_operator ProductsController::PAGE_SIZE, :<=, Catalog::ProductReader::MAX_LIMIT
  end

  test "empty pages are explicit and do not imply zero priced products" do
    get products_path(cursor: "1")

    assert_response :success
    assert_select "h1", text: "Browse the sample catalog"
    assert_select "h2", text: "No sample products on this page"
    refute_match(/free|\$0\.00|USD 0\.00/i, response.body)
  end

  test "malformed and non scalar cursors return a fixed 400 response" do
    [ "bad-cursor", "01", [ "0" ], { value: "0" } ].each do |cursor|
      get products_path, params: { cursor: }

      assert_response :bad_request
      assert_select "h1", text: "Catalog page unavailable"
      assert_select "p", text: "Check the catalog link and try again."
      refute_includes response.body, cursor.inspect
    end
  end

  test "unknown products return a fixed 404 response" do
    get product_path("unknown-product")

    assert_response :not_found
    assert_select "h1", text: "Sample product not found"
    assert_select "a[href='#{products_path}']", text: "Back to catalog"
    refute_includes response.body, "Catalog reader:"
  end

  test "source failures return a fixed 503 without exception payload or URL leakage" do
    reader = FailingReader.new("SECRET https://supplier.example/private")
    with_reader(reader) { get products_path }

    assert_response :service_unavailable
    assert_select "h1", text: "Sample catalog unavailable"
    assert_select "p", text: "Please try browsing again later."
    refute_includes response.body, "SECRET"
    refute_includes response.body, "supplier.example"
    refute_includes response.body, "Catalog reader:"
  end

  test "production fails generically before constructing a fixture reader" do
    production = ActiveSupport::EnvironmentInquirer.new("production")
    fixture_constructed = false

    with_singleton_method(Rails, :env, -> { production }) do
      replacement = lambda do |*|
        fixture_constructed = true
        flunk "fixture reader constructed"
      end
      with_singleton_method(Catalog::FixtureProductReader, :new, replacement) do
        get products_path
      end
    end

    assert_response :service_unavailable
    refute fixture_constructed
    assert_select "h1", text: "Sample catalog unavailable"
  end

  private
    class StaticReader
      attr_reader :list_calls

      def initialize(page:, product: nil)
        @page = page
        @product = product
        @list_calls = []
      end

      def list(limit:, cursor: nil)
        @list_calls << { limit:, cursor: }
        @page
      end

      def detail(id:)
        @product || raise(Catalog::ProductReader::Error.new(:not_found))
      end
    end

    class FailingReader
      def initialize(secret)
        @secret = secret
      end

      def list(limit:, cursor: nil)
        error = RuntimeError.new(@secret)
        raise Catalog::ProductReader::Error.new(:source_unavailable, retryable: true), cause: error
      end
    end

    def with_reader(reader)
      with_singleton_method(ProductsController, :build_product_reader, ->(**) { reader }) { yield }
    end

    def with_singleton_method(target, name, replacement)
      original = target.method(name)
      target.define_singleton_method(name, replacement)
      yield
    ensure
      target.define_singleton_method(name, original) if original
    end

    def catalog_page(product)
      Catalog::ProductReader::Page.new(items: [ product ], next_cursor: nil)
    end

    def catalog_product(title:, description:, images: [])
      observed_at = Time.iso8601("2026-09-20T00:00:00Z")
      freshness = Catalog::ProductReader::Freshness.new(state: :observed, observed_at:)
      price = Catalog::ProductReader::Price.new(state: :known, amount_minor: 1234, currency: "USD", freshness:)
      availability = Catalog::ProductReader::Availability.new(
        state: :unknown, quantity: nil, reason: :not_observed, freshness:
      )
      variant = Catalog::ProductReader::Variant.new(id: "variant-safe", sku: "SKU<SAFE>", title: "Variant <safe>",
        price:, availability:, weight: unknown_measurement, length: unknown_measurement,
        width: unknown_measurement, height: unknown_measurement)
      Catalog::ProductReader::Product.new(id: "product-safe", sku: "PRODUCT<SAFE>", title:, description:,
        images:, images_state: :known, variants: [ variant ], freshness:)
    end

    def unknown_measurement
      Catalog::ProductReader::Measurement.new(state: :unknown, value: nil, unit: nil)
    end
end
