require "test_helper"

# CAT-DB-READER-01 fix. Cart::CatalogVariantResolver's lazy-create path is
# keyed on (supplier, external_variant_id) -- the right lookup for
# Catalog::FixtureProductReader, whose ids are CJ external ids. Under
# Catalog::DatabaseProductReader the reader's ids are local ProductVariant
# public_ids (UUIDs), so that lookup can never hit: every add-to-cart of an
# already-imported real product creates a second, duplicate
# Product/SupplierProduct/SupplierVariant/ProductVariant row instead of
# linking to the one CAT-IMPORT-01 already created. This is the "adding a
# real product to a cart creates a duplicate row" defect found by hand-testing
# checkout against the real imported CJ catalog.
#
# Fix under test: Cart::CatalogVariantResolver must branch on
# product_reader.class::ID_SCHEME and, for :local_public_id, resolve directly
# by ProductVariant#public_id -- never create a row for that scheme.
class Cart::DatabaseReaderCatalogVariantResolverTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include TestSupport::IdentityRecords

  RECEIVED_AT = Time.utc(2026, 9, 20, 0, 0, 1).freeze

  setup do
    clean_catalog!
    clear_identity_records
    @supplier = Supplier.create!(key: "cj", display_name: "CJ Dropshipping",
      adapter_version: "1", api_version: "v1", status: "active")
    @importer = Catalog::ArtifactImporter.new
    @reader = Catalog::DatabaseProductReader.new
    @service = Cart::Service.new(resolver: Cart::CatalogVariantResolver.new(product_reader: @reader))
  end

  teardown do
    clean_catalog!
    clear_identity_records
  end

  test "the reader classes are tagged with the id scheme the resolver branches on" do
    assert_equal :local_public_id, Catalog::DatabaseProductReader::ID_SCHEME
    assert_equal :supplier_external, Catalog::FixtureProductReader::ID_SCHEME
  end

  test "adding an already-imported real product resolves to the existing row, never a duplicate" do
    import_product("00001234")
    import_inventory("00005678")
    catalog_product = @reader.detail(id: Product.find_by!(title: "Stacking storage bin").public_id)
    catalog_variant = catalog_product.variants.find { |variant| variant.sku == "FIXTURE-BIN-S" }
    existing_variant = ProductVariant.find_by!(public_id: catalog_variant.id)

    before_products = Product.count
    before_supplier_products = SupplierProduct.count
    before_supplier_variants = SupplierVariant.count

    session = create_shopping_session
    snapshot = @service.add_item(shopping_session: session, catalog_product_id: catalog_product.id,
      catalog_variant_id: catalog_variant.id, quantity: 2, client_mutation_id: SecureRandom.uuid)

    assert_equal before_products, Product.count
    assert_equal before_supplier_products, SupplierProduct.count
    assert_equal before_supplier_variants, SupplierVariant.count
    assert_equal 1, CartItem.count
    assert_equal existing_variant.id, CartItem.sole.product_variant_id
    assert_equal 2, snapshot.line_items.first.quantity
  end

  test "a variant id with no matching local public id is rejected, never fabricated" do
    resolver = Cart::CatalogVariantResolver.new(product_reader: LocalIdSchemeReader.new(ghost_product))
    session = create_shopping_session
    before_products = Product.count

    error = assert_raises(Cart::Error) do
      resolver.call(catalog_product_id: ghost_product.id, catalog_variant_id: ghost_product.variants.first.id)
    end

    assert_equal :not_found, error.code
    assert_equal before_products, Product.count
    assert_equal 0, SupplierProduct.count
    assert_equal 0, SupplierVariant.count
  end

  private
    def ghost_product
      @ghost_product ||= begin
        freshness = Catalog::ProductReader::Freshness.new(state: :observed, observed_at: RECEIVED_AT)
        variant = Catalog::ProductReader::Variant.new(
          id: SecureRandom.uuid, sku: nil, title: "Ghost variant",
          price: Catalog::ProductReader::Price.new(state: :known, amount_minor: 100, currency: "USD", freshness: freshness),
          availability: Catalog::ProductReader::Availability.new(state: :available, quantity: 1, reason: :observed, freshness: freshness),
          weight: Catalog::ProductReader::Measurement.new(state: :unknown, value: nil, unit: nil),
          length: Catalog::ProductReader::Measurement.new(state: :unknown, value: nil, unit: nil),
          width: Catalog::ProductReader::Measurement.new(state: :unknown, value: nil, unit: nil),
          height: Catalog::ProductReader::Measurement.new(state: :unknown, value: nil, unit: nil)
        )
        Catalog::ProductReader::Product.new(id: SecureRandom.uuid, sku: nil, title: "Ghost product",
          description: nil, images: [], images_state: :unknown, variants: [ variant ], freshness: freshness)
      end
    end

    def import_product(product_id)
      @importer.call(supplier: @supplier, operation: :product,
        artifact_bytes: product_artifact_bytes(product_id), received_at: RECEIVED_AT)
    end

    def import_inventory(variant_id)
      @importer.call(supplier: @supplier, operation: :inventory,
        artifact_bytes: inventory_artifact_bytes(variant_id), received_at: RECEIVED_AT)
    end

    def product_artifact_bytes(product_id)
      entry_bytes(:product, ->(entry) { entry.dig("request", "product_id") == product_id })
    end

    def inventory_artifact_bytes(variant_id)
      entry_bytes(:inventory, ->(entry) { entry.dig("request", "variant_id") == variant_id })
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
        supplier_observations supplier_warehouses cart_mutations cart_items carts supplier_variants
        supplier_products product_variants products suppliers]
      connection.disable_referential_integrity do
        tables.each { |table| connection.execute("TRUNCATE TABLE #{table} RESTART IDENTITY CASCADE") }
      end
    end

    # Stands in for Catalog::DatabaseProductReader for the one test that needs a
    # reader response whose variant id has no matching local row. ID_SCHEME is the
    # only thing the resolver is supposed to read off a reader's class, so a bare
    # object exposing just that constant plus #detail is enough.
    class LocalIdSchemeReader
      ID_SCHEME = :local_public_id

      def initialize(product)
        @product = product
      end

      def detail(id:)
        @product
      end
    end
end
