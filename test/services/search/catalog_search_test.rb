require "test_helper"

class Search::CatalogSearchTest < ActiveSupport::TestCase
  test "resolves ranked lexical matches to full catalog product reader entries" do
    product = link_search_document!(external_product_id: "ext-1", title: "Stacking storage bin",
      normalized_text: "Stacking storage bin")

    reader = FakeProductReader.new({ "ext-1" => build_product(id: "ext-1", title: "Stacking storage bin") })
    result = Search::CatalogSearch.new(product_reader: reader).call(query: "storage bin")

    assert_equal "storage bin", result.query
    assert_equal [ "ext-1" ], result.items.map(&:id)
    assert product.persisted?
  end

  test "a query matching nothing returns an explicit empty result, not an error" do
    link_search_document!(external_product_id: "ext-1", title: "Stacking storage bin",
      normalized_text: "Stacking storage bin")
    reader = FakeProductReader.new({ "ext-1" => build_product(id: "ext-1", title: "Stacking storage bin") })

    result = Search::CatalogSearch.new(product_reader: reader).call(query: "nonexistent-widget-zzz")

    assert_equal [], result.items
  end

  test "with no indexed documents at all, the result is an empty list rather than a failure" do
    reader = FakeProductReader.new({})

    result = Search::CatalogSearch.new(product_reader: reader).call(query: "anything")

    assert_equal [], result.items
  end

  test "a blank, over-long, or non-string query never raises and returns no matches" do
    reader = FakeProductReader.new({})

    [ "", "   ", "x" * 500, nil, 5 ].each do |query|
      result = Search::CatalogSearch.new(product_reader: reader).call(query: query)
      assert_equal [], result.items
    end
  end

  test "SQL metacharacters and quotes in the query are handled safely without raising" do
    link_search_document!(external_product_id: "ext-1", title: "Stacking storage bin",
      normalized_text: "Stacking storage bin")
    reader = FakeProductReader.new({ "ext-1" => build_product(id: "ext-1", title: "Stacking storage bin") })

    result = Search::CatalogSearch.new(product_reader: reader).call(query: "'; DROP TABLE search_documents; --")

    assert_equal [], result.items
    assert ActiveRecord::Base.connection.data_source_exists?("search_documents")
  end

  test "a resolved product the reader can no longer read is skipped, not fabricated" do
    link_search_document!(external_product_id: "missing", title: "Ghost product", normalized_text: "Ghost product")
    reader = FakeProductReader.new({})

    result = Search::CatalogSearch.new(product_reader: reader).call(query: "ghost")

    assert_equal [], result.items
  end

  private
    def link_search_document!(external_product_id:, title:, normalized_text:)
      supplier = Supplier.create!(key: "cj-#{unique_suffix}", display_name: "CJ", adapter_version: "1",
        api_version: "v1", status: "active")
      product = Product.create!(title: title, description: "", status: "draft")
      SupplierProduct.create!(supplier: supplier, product: product, external_product_id: external_product_id,
        status: "observed", first_seen_at: Time.current, last_seen_at: Time.current, adapter_version: "1")
      SearchDocument.create!(product: product, document_kind: "listing", locale: "en",
        normalized_text: normalized_text, content_hash: Digest::SHA256.digest("#{normalized_text}-#{unique_suffix}"),
        source_version: "v#{unique_suffix}", status: "active", generated_at: Time.current)
      product
    end

    def unique_suffix
      SecureRandom.hex(4)
    end

    def build_product(id:, title:)
      Catalog::ProductReader.deep_freeze(Catalog::ProductReader::Product.new(
        id: id, sku: nil, title: title, description: nil, images: [], images_state: :unknown,
        variants: [], freshness: Catalog::ProductReader::Freshness.new(state: :unknown, observed_at: nil)))
    end

    class FakeProductReader
      def initialize(products_by_id)
        @products_by_id = products_by_id
      end

      def detail(id:)
        @products_by_id.fetch(id) { raise Catalog::ProductReader::Error.new(:not_found) }
      end
    end
end
