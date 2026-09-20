require "test_helper"

class CatalogSearchTest < ActionDispatch::IntegrationTest
  test "with no indexed documents, the catalog still renders the unfiltered listing" do
    get products_path

    assert_response :success
    assert_select "h1", text: "Browse the sample catalog"
    assert_select "article", count: Catalog::FixtureProductReader::DEFAULT_PRODUCT_IDS.size
    assert_select "input#search"
  end

  test "searching returns matching products resolved through the lexical index" do
    link_search_document!(external_product_id: "00001234", title: "Stacking storage bin",
      normalized_text: "Stacking storage bin A reusable storage bin.")

    get products_path(search: "storage bin")

    assert_response :success
    assert_select "article", count: 1
    assert_select "a[href='#{product_path('00001234')}']", text: "Stacking storage bin"
    assert_select "input#search[value='storage bin']"
  end

  test "a query matching nothing renders a clear empty state rather than an error" do
    get products_path(search: "nonexistent-widget-zzz")

    assert_response :success
    assert_select "h2", text: /No results for/
    assert_select "h1", text: "Browse the sample catalog"
  end

  test "an empty or whitespace-only query behaves as no query" do
    get products_path(search: "   ")

    assert_response :success
    assert_select "article", count: Catalog::FixtureProductReader::DEFAULT_PRODUCT_IDS.size
    assert_select "h2", text: /No results for/, count: 0
  end

  test "an over-long query is bounded rather than erroring" do
    get products_path(search: "x" * 5000)

    assert_response :success
    refute_includes response.body, "x" * 500
  end

  test "HTML and SQL metacharacters in the query are handled safely and escaped when echoed back" do
    query = %(<script>alert(1)</script>' OR '1'='1)
    get products_path(search: query)

    assert_response :success
    refute_includes response.body, "<script>alert(1)</script>"
    assert_includes response.body, "&lt;script&gt;"
    assert ActiveRecord::Base.connection.data_source_exists?("search_documents")
  end

  test "a non-string search parameter is treated as no query" do
    get products_path(search: [ "a", "b" ])

    assert_response :success
    assert_select "article", count: Catalog::FixtureProductReader::DEFAULT_PRODUCT_IDS.size
  end

  private
    def link_search_document!(external_product_id:, title:, normalized_text:)
      supplier = Supplier.create!(key: "cj-#{SecureRandom.hex(4)}", display_name: "CJ", adapter_version: "1",
        api_version: "v1", status: "active")
      product = Product.create!(title: title, description: "", status: "draft")
      SupplierProduct.create!(supplier: supplier, product: product, external_product_id: external_product_id,
        status: "observed", first_seen_at: Time.current, last_seen_at: Time.current, adapter_version: "1")
      SearchDocument.create!(product: product, document_kind: "listing", locale: "en",
        normalized_text: normalized_text, content_hash: Digest::SHA256.digest(normalized_text),
        source_version: "v1", status: "active", generated_at: Time.current)
    end
end
