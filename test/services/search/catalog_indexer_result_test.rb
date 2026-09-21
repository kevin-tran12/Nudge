require "test_helper"

# CAT-DB-READER-01 fix #5. lib/tasks/catalog.rake's catalog:sync summary prints
# Search::CatalogIndexer::Result#processed (products attempted) as "indexed=",
# so an operator cannot tell "we tried N products" from "N products are now
# actually searchable" -- a product that comes back :skipped or :unchanged
# still counts toward processed. Result must expose the real indexed count
# (created + superseded -- rows that are active with new content after this
# run) separately, so the rake task can print that instead of the attempted
# count.
#
# This is deliberately a service-level test, not a rake-level one: catalog:sync
# only reaches Search::CatalogIndexer through CATALOG_SYNC_MODE=record, and the
# test environment's Integrations::Cj::ModePolicy fails record mode closed
# before any capture/reindex runs (see test/lib/tasks/catalog_sync_rake_test.rb
# "record mode still fails closed in a deployment that does not allow it"), so
# the rake task itself can never be driven far enough in this suite to observe
# the printed indexed= figure end to end.
class Search::CatalogIndexerResultTest < ActiveSupport::TestCase
  setup do
    @supplier = Supplier.create!(key: "supplier-#{SecureRandom.hex(4)}", display_name: "Fixture",
      adapter_version: "1", api_version: "v1", status: "active")
  end

  test "indexed counts created and superseded rows but excludes skipped and unchanged" do
    link_local_product!(external_id: "ext-linked", title: "Stacking storage bin")
    reader = FakeProductReader.new([
      build_product(id: "ext-linked", title: "Stacking storage bin", description: "A reusable storage bin."),
      build_product(id: "ext-unmapped", title: "Ghost product")
    ])

    first = Search::CatalogIndexer.new(product_reader: reader).call
    assert_equal 2, first.processed
    assert_equal 1, first.created
    assert_equal 1, first.skipped
    assert_equal 1, first.indexed, "indexed must count the created row but not the skipped one"

    second = Search::CatalogIndexer.new(product_reader: reader).call
    assert_equal 1, second.unchanged
    assert_equal 0, second.indexed, "an unchanged re-index has nothing new to report as indexed"

    changed_reader = FakeProductReader.new([
      build_product(id: "ext-linked", title: "Stacking storage bin, extra large",
        description: "A reusable storage bin."),
      build_product(id: "ext-unmapped", title: "Ghost product")
    ])
    third = Search::CatalogIndexer.new(product_reader: changed_reader).call
    assert_equal 1, third.superseded
    assert_equal 1, third.indexed, "a superseded (content-changed) row counts as indexed"
  end

  private
    def link_local_product!(external_id:, title:)
      product = Product.create!(title: title, description: "", status: "draft")
      SupplierProduct.create!(supplier: @supplier, product: product, external_product_id: external_id,
        status: "observed", first_seen_at: Time.current, last_seen_at: Time.current, adapter_version: "1")
      product
    end

    def build_product(id:, title:, description: nil)
      Catalog::ProductReader.deep_freeze(Catalog::ProductReader::Product.new(
        id: id, sku: nil, title: title, description: description, images: [], images_state: :unknown,
        variants: [], freshness: Catalog::ProductReader::Freshness.new(state: :unknown, observed_at: nil)
      ))
    end

    class FakeProductReader
      Page = Catalog::ProductReader::Page

      def initialize(products)
        @products = products
      end

      def list(limit:, cursor: nil)
        offset = cursor.to_i
        items = @products.slice(offset, limit) || []
        next_offset = offset + items.length
        next_cursor = next_offset < @products.length ? next_offset.to_s : nil
        Page.new(items: items, next_cursor: next_cursor)
      end
    end
end
