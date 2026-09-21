require "test_helper"
require "json"
require "uri"

# CJ-LIVE-IMPORT-01. The whole path a live catalog import takes, offline: a
# realistic CJ product and inventory response are validated by
# Integrations::Cj::RecordArtifactValidator, imported by
# Catalog::ArtifactImporter, and then read back through the app's own
# Catalog::DatabaseProductReader. Until the attribute rule was narrowed the
# product never got past validation, so nothing downstream had ever been
# exercised against a body shaped like the real thing.
class CjLiveImportPathTest < ActiveSupport::TestCase
  include TestSupport::CjLiveResponseShapes

  self.use_transactional_tests = false

  OBSERVED_AT = "2026-09-20T12:00:00Z".freeze
  RECEIVED_AT = Time.utc(2026, 9, 20, 13, 0, 0).freeze

  setup do
    clean_catalog!
    @supplier = Supplier.create!(key: "cj", display_name: "CJ Dropshipping",
      adapter_version: "1", api_version: "v1", status: "active")
    @validator = Integrations::Cj::RecordArtifactValidator.new
    @importer = Catalog::ArtifactImporter.new
  end

  teardown { clean_catalog! }

  test "a realistic CJ product and inventory import and read back through the catalog reader" do
    refute_socket_opened { import_live_product_and_inventory }

    reader = Catalog::DatabaseProductReader.new
    listed = reader.list(limit: 24).items
    assert_equal 1, listed.size

    product = reader.detail(id: listed.first.id)

    assert_equal "Dog Toy Candy Tennis Ball Glowing", product.title
    assert_equal "CJYD3170983", product.sku
    assert_equal 2, product.variants.size

    priced = product.variants.map(&:price).select { |price| price.state == :known }
    assert_equal 2, priced.size
    assert_equal [ 138 ], priced.map(&:amount_minor).uniq
    assert_equal [ "USD" ], priced.map(&:currency).uniq

    assert_equal :known, product.images_state
    refute_empty product.images
    assert_equal [ "oss-cf.cjdropshipping.com" ], product.images.map { |i| URI.parse(i.url).host }.uniq
    assert product.images.all? { |image| image.url.start_with?("https://") }

    stocked = product.variants.find { |variant| variant.availability.state == :available }
    assert_equal 5675, stocked.availability.quantity
  end

  test "the supplier HTML is persisted as evidence and stripped to plain text on read" do
    import_live_product_and_inventory

    evidence = SupplierObservation.find_by!(supplier: @supplier, resource_kind: "product",
      external_resource_id: LIVE_PRODUCT_ID)
    stored = evidence.payload_json.dig("response", "data", "description")
    assert_includes stored, "<img"
    assert_includes stored, "oss-cf.cjdropshipping.com"

    product = Catalog::DatabaseProductReader.new.detail(id: ::Product.sole.public_id)
    assert_includes product.description, "Product information"
    refute_includes product.description, "<"
    refute_includes product.description, "oss-cf.cjdropshipping.com"
  end

  private
    def import_live_product_and_inventory
      @importer.call(supplier: @supplier, operation: :product,
        artifact_bytes: validated(:product).artifact_bytes, received_at: RECEIVED_AT)
      @importer.call(supplier: @supplier, operation: :inventory,
        artifact_bytes: validated(:inventory).artifact_bytes, received_at: RECEIVED_AT)
    end

    def validated(operation)
      body = operation == :product ? live_product_body : live_inventory_body
      request = operation == :product ? { "product_id" => LIVE_PRODUCT_ID } : { "variant_id" => LIVE_VARIANT_ID }
      @validator.call(operation:, request:, raw_body: JSON.generate(body), observed_at: OBSERVED_AT)
    end

    def clean_catalog!
      connection = ApplicationRecord.connection
      tables = %w[sync_checkpoints sync_runs catalog_media inventory_observations price_observations
        supplier_observations supplier_warehouses supplier_variants supplier_products product_variants
        products suppliers]
      connection.disable_referential_integrity do
        tables.each { |table| connection.execute("TRUNCATE TABLE #{table} RESTART IDENTITY CASCADE") }
      end
    end
end
