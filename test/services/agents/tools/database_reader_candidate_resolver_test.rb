require "test_helper"

# CAT-DB-READER-01 fix. Agents::Tools::CandidateResolver looks a search hit's
# catalog facts up by calling product_reader.detail(id: external_product_id),
# where external_product_id comes from SupplierProduct -- the right id for
# Catalog::FixtureProductReader. Under Catalog::DatabaseProductReader that id
# (a CJ external id like "00001234") fails the reader's UUID id_pattern,
# detail raises invalid_input, CandidateResolver rescues Catalog::ProductReader::Error
# and silently drops the candidate, and recommend_products/search_products
# return nothing for every real, imported product.
#
# Fix under test: for @product_reader.class::ID_SCHEME == :local_public_id,
# the resolver must call detail(id: product.public_id) instead.
class Agents::Tools::DatabaseReaderCandidateResolverTest < ActiveSupport::TestCase
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

  test "resolves a real imported product and its default variant back to the reader's own DTOs" do
    import_product("00001234")
    product = Product.find_by!(title: "Stacking storage bin")
    variant = product.product_variants.order(:id).first
    item = Search::LexicalRetrieval::Item.new(search_document_id: 1, product_id: product.id,
      product_variant_id: nil, document_kind: "listing", rank: 1.0)

    candidates = Agents::Tools::CandidateResolver.new(product_reader: @reader).resolve([ item ])

    assert_equal 1, candidates.length
    candidate = candidates.first
    assert_equal product.id, candidate.product.id
    assert_equal variant.id, candidate.variant.id
    assert_equal product.public_id, candidate.catalog_product.id
    assert_equal variant.public_id, candidate.catalog_variant.id
  end

  test "preserves retrieval order across several real imported products" do
    %w[00001234 00002001].each { |id| import_product(id) }
    bin = Product.find_by!(title: "Stacking storage bin")
    other = Product.where.not(id: bin.id).first!
    items = [ other, bin ].map.with_index do |product, index|
      Search::LexicalRetrieval::Item.new(search_document_id: index, product_id: product.id,
        product_variant_id: nil, document_kind: "listing", rank: 1.0)
    end

    candidates = Agents::Tools::CandidateResolver.new(product_reader: @reader).resolve(items)

    assert_equal [ other.id, bin.id ], candidates.map { |candidate| candidate.product.id }
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
