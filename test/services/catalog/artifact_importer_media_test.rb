require "test_helper"

# CAT-MEDIA-01: Catalog::ArtifactImporter persists productImageSet entries
# into catalog_media so Catalog::DatabaseProductReader stops reporting
# images_state: :unknown for imported products. These tests exercise only
# the media-writing seam; the rest of ArtifactImporter's product/variant
# behavior is already covered by CatalogArtifactImporterTest.
class CatalogArtifactImporterMediaTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  RECEIVED_AT = Time.utc(2026, 9, 20, 0, 0, 1).freeze

  setup do
    clean_catalog!
    @supplier = Supplier.create!(key: "cj", display_name: "CJ Dropshipping",
      adapter_version: "1", api_version: "v1", status: "active")
    @importer = Catalog::ArtifactImporter.new
  end

  teardown { clean_catalog! }

  test "imports the productImageSet into catalog_media with position and observation linkage" do
    result = import_product
    product = Product.find_by!(title: "Stacking storage bin")
    observation = SupplierObservation.find_by!(resource_kind: "product", external_resource_id: "00001234")

    media = CatalogMedia.where(product_id: product.id).order(:position)
    assert_equal 1, media.count
    row = media.first
    assert_equal "image", row.kind
    assert_equal "active", row.status
    assert_equal 0, row.position
    assert_equal "https://cf.cjdropshipping.com/fixture/storage-bin.jpg", row.sanitized_url
    assert_equal observation.id, row.supplier_observation_id
    assert_equal observation.observed_at, row.observed_at
    assert_nil row.product_variant_id
    assert_equal false, result.dry_run?
  end

  test "the database reader returns the imported images, no longer reporting images_state unknown" do
    import_product
    reader = Catalog::DatabaseProductReader.new
    product = reader.detail(id: Product.find_by!(title: "Stacking storage bin").public_id)

    assert_equal :known, product.images_state
    assert_equal [ "https://cf.cjdropshipping.com/fixture/storage-bin.jpg" ], product.images.map(&:url)
    assert_equal [ 0 ], product.images.map(&:position)
  end

  test "an artifact with no productImageSet imports cleanly and yields no media rows" do
    json = fixture_json
    json["response"]["data"].delete("productImageSet")
    @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(json), received_at: RECEIVED_AT)

    product = Product.find_by!(title: "Stacking storage bin")
    assert_equal 0, CatalogMedia.where(product_id: product.id).count

    reader = Catalog::DatabaseProductReader.new
    read_back = reader.detail(id: product.public_id)
    assert_equal :unknown, read_back.images_state
    assert_empty read_back.images
  end

  test "re-importing the identical artifact is a no-op for catalog_media" do
    import_product
    before = CatalogMedia.order(:id).to_a.map(&:attributes)

    replay = import_product
    assert replay.replayed?
    assert_equal before, CatalogMedia.order(:id).to_a.map(&:attributes)
  end

  test "a changed image set converges instead of accumulating stale rows" do
    import_product
    product = Product.find_by!(title: "Stacking storage bin")
    assert_equal [ "https://cf.cjdropshipping.com/fixture/storage-bin.jpg" ],
      CatalogMedia.where(product_id: product.id).order(:position).pluck(:sanitized_url)

    json = fixture_json
    json["observed_at"] = "2026-09-20T00:00:02Z"
    json["response"]["requestId"] = "fixture-product-images-changed"
    json["response"]["data"]["productImageSet"] = [
      "https://cf.cjdropshipping.com/fixture/storage-bin.jpg",
      "https://cc-west-usa.oss-us-west-1.aliyuncs.com/fixture/storage-bin-alt.jpg"
    ]
    @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(json), received_at: RECEIVED_AT + 2.seconds)

    rows = CatalogMedia.where(product_id: product.id).order(:position)
    assert_equal 2, rows.count
    assert_equal [ "https://cf.cjdropshipping.com/fixture/storage-bin.jpg",
      "https://cc-west-usa.oss-us-west-1.aliyuncs.com/fixture/storage-bin-alt.jpg" ], rows.map(&:sanitized_url)
    assert_equal [ 0, 1 ], rows.map(&:position)

    # Drop back to a single, different image; the stale row must not remain.
    json["observed_at"] = "2026-09-20T00:00:03Z"
    json["response"]["requestId"] = "fixture-product-images-narrowed"
    json["response"]["data"]["productImageSet"] = [
      "https://cc-west-usa.oss-us-west-1.aliyuncs.com/fixture/storage-bin-alt.jpg"
    ]
    @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(json), received_at: RECEIVED_AT + 3.seconds)

    rows = CatalogMedia.where(product_id: product.id).order(:position)
    assert_equal 1, rows.count
    assert_equal "https://cc-west-usa.oss-us-west-1.aliyuncs.com/fixture/storage-bin-alt.jpg",
      rows.first.sanitized_url
    assert_equal 0, rows.first.position
  end

  test "a dry run writes no media rows" do
    before = CatalogMedia.count
    result = @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: fixture_bytes, received_at: RECEIVED_AT, dry_run: true)

    assert result.dry_run?
    assert_equal before, CatalogMedia.count
  end

  test "makes zero network calls while importing images" do
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*, **| raise "unexpected network call" }
    begin
      import_product
    ensure
      Net::HTTP.define_singleton_method(:start, original)
    end
    assert_equal 1, CatalogMedia.count
  end

  test "an image on a non-approved host fails the whole import rather than being silently skipped" do
    assert_unsafe_media_url { |json| json["response"]["data"]["productImageSet"] = [ "https://supplier.example/private.jpg" ] }
  end

  test "a non-HTTPS image url fails the whole import" do
    assert_unsafe_media_url { |json| json["response"]["data"]["productImageSet"] = [ "http://cf.cjdropshipping.com/fixture/storage-bin.jpg" ] }
  end

  test "an image url with userinfo fails the whole import" do
    assert_unsafe_media_url { |json| json["response"]["data"]["productImageSet"] = [ "https://user:pass@cf.cjdropshipping.com/fixture/storage-bin.jpg" ] }
  end

  test "an image url with a query string fails the whole import" do
    assert_unsafe_media_url { |json| json["response"]["data"]["productImageSet"] = [ "https://cf.cjdropshipping.com/fixture/storage-bin.jpg?x=1" ] }
  end

  test "an image url with a fragment fails the whole import" do
    assert_unsafe_media_url { |json| json["response"]["data"]["productImageSet"] = [ "https://cf.cjdropshipping.com/fixture/storage-bin.jpg#frag" ] }
  end

  private
    def import_product
      @importer.call(supplier: @supplier, operation: :product,
        artifact_bytes: fixture_bytes, received_at: RECEIVED_AT)
    end

    def fixture_bytes
      JSON.generate(fixture_json)
    end

    def fixture_json
      fixture = JSON.parse(Rails.root.join("test/fixtures/files/cj/v1/product.json").binread)
      entry = fixture.fetch("entries").first
      { "fixture_version" => Integrations::Cj::RecordArtifactValidator::FIXTURE_VERSION,
        "observed_at" => fixture.fetch("observed_at"), "request" => entry.fetch("request"),
        "response" => entry.fetch("response") }
    end

    # An image URL this far off the approved-host allowlist is rejected by
    # Integrations::Cj::Normalizer before ArtifactImporter ever sees it, so
    # this asserts the artifact is rejected wholesale (no product, no
    # variant, no media row survives) with zero durable side effects,
    # matching how every other malformed-artifact case in this importer
    # behaves, rather than silently dropping just the bad image.
    def assert_unsafe_media_url
      json = fixture_json
      yield json

      error = assert_raises(Catalog::ArtifactImporter::Error) do
        @importer.call(supplier: @supplier, operation: :product,
          artifact_bytes: JSON.generate(json), received_at: RECEIVED_AT)
      end
      assert_equal :invalid_artifact, error.code
      assert_equal 0, Product.count
      assert_equal 0, CatalogMedia.count
      assert_equal 0, SupplierObservation.count
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
