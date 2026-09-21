require "test_helper"

# CAT-DB-READER-01 fix. Search::CatalogIndexer#index_product looks a product
# up by asking SupplierProduct for the CJ external_product_id -- the right
# lookup for Catalog::FixtureProductReader, whose ids are that same external
# id. Under Catalog::DatabaseProductReader the reader's ids are local
# Product#public_id (UUIDs), so that lookup can never hit: every product
# catalog:sync imports comes back :skipped here, and the search index stays
# permanently empty even though catalog:sync reports success.
#
# Fix under test: for @product_reader.class::ID_SCHEME == :local_public_id,
# index_product must resolve the product directly by Product#public_id
# instead of going through SupplierProduct.
class Search::DatabaseReaderCatalogIndexerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  RECEIVED_AT = Time.utc(2026, 9, 20, 0, 0, 1).freeze

  setup do
    clean_catalog!
    @supplier = Supplier.create!(key: "cj", display_name: "CJ Dropshipping",
      adapter_version: "1", api_version: "v1", status: "active")
    @importer = Catalog::ArtifactImporter.new
    @reader = Catalog::DatabaseProductReader.new
  end

  teardown { clean_catalog! }

  test "a product imported through the database reader is indexed, not skipped" do
    import_product("00001234")
    product = Product.find_by!(title: "Stacking storage bin")

    result = Search::CatalogIndexer.new(product_reader: @reader).call

    assert_equal 1, result.processed
    assert_equal 1, result.created
    assert_equal 0, result.skipped
    document = SearchDocument.sole
    assert_equal product.id, document.product_id
    assert_equal "active", document.status
    assert_includes document.normalized_text, "Stacking storage bin"
  end

  test "re-running with no content change reports unchanged, not a repeated skip" do
    import_product("00001234")
    Search::CatalogIndexer.new(product_reader: @reader).call

    second = Search::CatalogIndexer.new(product_reader: @reader).call

    assert_equal 1, second.processed
    assert_equal 0, second.created
    assert_equal 1, second.unchanged
    assert_equal 0, second.skipped
    assert_equal 1, SearchDocument.count
  end

  private
    def import_product(product_id)
      @importer.call(supplier: @supplier, operation: :product,
        artifact_bytes: product_artifact_bytes(product_id), received_at: RECEIVED_AT)
    end

    def product_artifact_bytes(product_id)
      entry_bytes(:product, ->(entry) { entry.dig("request", "product_id") == product_id })
    end

    def entry_bytes(operation, matcher)
      fixture = JSON.parse(Rails.root.join("test/fixtures/files/cj/v1/#{operation}.json").binread)
      entry = fixture.fetch("entries").find(&matcher)
      JSON.generate("fixture_version" => Integrations::Cj::RecordArtifactValidator::FIXTURE_VERSION,
        "observed_at" => fixture.fetch("observed_at"), "request" => entry.fetch("request"),
        "response" => entry.fetch("response"))
    end

    def clean_catalog!
      connection = ApplicationRecord.connection
      tables = %w[sync_checkpoints sync_runs catalog_media inventory_observations price_observations
        supplier_observations supplier_warehouses supplier_variants supplier_products product_variants
        products suppliers search_documents]
      connection.disable_referential_integrity do
        tables.each { |table| connection.execute("TRUNCATE TABLE #{table} RESTART IDENTITY CASCADE") }
      end
    end
end
