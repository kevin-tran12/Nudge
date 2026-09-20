require "test_helper"

class Search::CatalogIndexingJobTest < ActiveSupport::TestCase
  test "performing the job runs the catalog indexer" do
    supplier = Supplier.create!(key: "cj-#{SecureRandom.hex(4)}", display_name: "CJ", adapter_version: "1", api_version: "v1", status: "active")
    product = Product.create!(title: "Stacking storage bin", description: "A reusable storage bin.", status: "draft")
    SupplierProduct.create!(supplier: supplier, product: product, external_product_id: "00001234",
      status: "observed", first_seen_at: Time.current, last_seen_at: Time.current, adapter_version: "1")

    assert_difference "SearchDocument.count", 1 do
      Search::CatalogIndexingJob.perform_now
    end
  end
end
