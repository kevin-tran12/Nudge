require "test_helper"
require "json"
require "net/http"
require "socket"

# CJ-REAL-SHAPE-01. The committed allowlists were derived from hand-sanitized
# fixtures and were narrower than what CJ actually returns, so every genuine
# response was rejected as :malformed_response. These bodies reproduce the
# field sets captured from live authenticated CJ calls on 2026-09-20.
#
# Entirely offline: every byte here is a literal in this file.
class CjRecordArtifactRealShapeTest < ActiveSupport::TestCase
  OBSERVED_AT = "2026-09-20T00:00:00Z".freeze
  IMAGE = "https://cf.cjdropshipping.com/live/pet-bowl.jpg".freeze
  Validator = Integrations::Cj::RecordArtifactValidator

  PRODUCT_DATA_KEYS = %w[
    addMarkStatus bigImage categoryId categoryName createrTime customizationJson1 customizationJson2
    customizationJson3 customizationJson4 customizationVersion description entryCode entryName entryNameEn
    isTestProduct listedNum materialKey materialKeySet materialName materialNameEn materialNameEnSet
    materialNameSet packingKey packingKeySet packingName packingNameEn packingNameEnSet packingNameSet
    packingWeight pid productImage productImageSet productKey productKeyEn productKeyEnSet productKeySet
    productName productNameEn productNameSet productPro productProEn productProEnSet productProSet productSku
    productType productUnit productVideo productWeight sellPrice sourceFrom status suggestSellPrice
    supplierId supplierName variants
  ].freeze

  VARIANT_DATA_KEYS = %w[
    barcode combineNum combineVariants createTime inventories inventoryNum pid variantHeight variantImage
    variantKey variantLength variantName variantNameEn variantProperty variantSellPrice variantSku
    variantStandard variantSugSellPrice variantUnit variantVolume variantWeight variantWidth vid
  ].freeze

  LIST_ENVELOPE_KEYS = %w[list pageNum pageSize total].freeze

  LIST_ITEM_KEYS = %w[
    addMarkStatus categoryId categoryName createTime customizationVersion isFreeShipping isTestProduct
    isVideo listedNum listingCount oneCategoryId oneCategoryName pid productImage productName productNameEn
    productSku productType productUnit productWeight remark saleStatus sellPrice shippingCountryCodes
    sourceFrom supplierId supplierName threeCategoryName twoCategoryId twoCategoryName
  ].freeze

  INVENTORY_ROW_KEYS = %w[
    areaEn areaId cjInventoryNum countryCode factoryInventoryNum stock storageNum totalInventoryNum vid
  ].freeze

  test "the observed live field sets are exactly what the validator allows" do
    assert_equal PRODUCT_DATA_KEYS.sort, Validator::PRODUCT_KEYS.sort
    assert_equal VARIANT_DATA_KEYS.sort, Validator::VARIANT_KEYS.sort
    assert_equal LIST_ENVELOPE_KEYS.sort, Validator::PRODUCT_LIST_KEYS.sort
    assert_equal LIST_ITEM_KEYS.sort, Validator::PRODUCT_LIST_ITEM_KEYS.sort
    assert_equal INVENTORY_ROW_KEYS.sort, Validator::INVENTORY_KEYS.sort
    assert_equal %w[factoryInventory inventory stockId], Validator::STOCK_KEYS.sort
    assert_equal 55, PRODUCT_DATA_KEYS.size
    assert_equal 23, VARIANT_DATA_KEYS.size
    assert_equal 30, LIST_ITEM_KEYS.size
    assert_equal 9, INVENTORY_ROW_KEYS.size
  end

  test "a realistic live product response with every observed field validates" do
    body = product_body
    assert_equal 55, body.fetch("data").keys.size
    assert_equal 23, body.dig("data", "variants").first.keys.size

    result = validator.call(operation: :product, request: { "product_id" => "00001234" },
      raw_body: JSON.generate(body), observed_at: OBSERVED_AT)

    assert_equal "00001234", result.normalized.value.external_id
    assert_equal %w[00005678 00005679], result.normalized.value.variants.map(&:external_id)
    assert_equal result.artifact_sha256, result.provenance.payload_sha256
  end

  test "a realistic live product list response with every observed field validates" do
    body = list_body
    assert_equal 4, body.fetch("data").keys.size
    assert_equal 30, body.dig("data", "list").first.keys.size

    result = validator.call(operation: :product_list, request: list_request,
      raw_body: JSON.generate(body), observed_at: OBSERVED_AT)

    assert_equal %w[00003001], result.normalized.value.products.map(&:external_id)
    assert_equal 1, result.normalized.value.page
  end

  test "a realistic live inventory response with every observed field validates" do
    body = inventory_body
    assert_equal 9, body.fetch("data").first.keys.size

    result = validator.call(operation: :inventory, request: { "variant_id" => "00005678" },
      raw_body: JSON.generate(body), observed_at: OBSERVED_AT)

    assert_equal [ "00005678" ], result.normalized.value.map(&:variant_id)
    assert_equal [ "CN" ], result.normalized.value.map(&:country_code)
  end

  test "an unknown field outside the observed sets is still rejected" do
    product_cases = [
      product_body.tap { |body| body["data"]["injectedField"] = "x" },
      product_body.tap { |body| body["data"]["variants"].first["injectedField"] = "x" }
    ]
    product_cases.each do |body|
      assert_malformed do
        validator.call(operation: :product, request: { "product_id" => "00001234" },
          raw_body: JSON.generate(body), observed_at: OBSERVED_AT)
      end
    end

    inventory_cases = [
      inventory_body.tap { |body| body["data"].first["injectedField"] = "x" },
      inventory_body.tap { |body| body["data"].first["stock"].first["injectedField"] = "x" }
    ]
    inventory_cases.each do |body|
      assert_malformed do
        validator.call(operation: :inventory, request: { "variant_id" => "00005678" },
          raw_body: JSON.generate(body), observed_at: OBSERVED_AT)
      end
    end

    list_cases = [
      list_body.tap { |body| body["data"]["injectedField"] = "x" },
      list_body.tap { |body| body["data"]["list"].first["injectedField"] = "x" }
    ]
    list_cases.each do |body|
      assert_malformed do
        validator.call(operation: :product_list, request: list_request,
          raw_body: JSON.generate(body), observed_at: OBSERVED_AT)
      end
    end
  end

  test "a credential or PII shaped field is still rejected inside the widened sets" do
    %w[accessToken access_token apiKey email phone recipientName address1 zipCode password signature].each do |key|
      body = product_body
      body["data"][key] = "SYNTHETIC-SECRET"
      assert_malformed do
        validator.call(operation: :product, request: { "product_id" => "00001234" },
          raw_body: JSON.generate(body), observed_at: OBSERVED_AT)
      end

      nested = product_body
      nested["data"]["variants"].first[key] = "SYNTHETIC-SECRET"
      assert_malformed do
        validator.call(operation: :product, request: { "product_id" => "00001234" },
          raw_body: JSON.generate(nested), observed_at: OBSERVED_AT)
      end
    end
  end

  test "no newly allowed field name collides with a forbidden key" do
    allowed = Validator::PRODUCT_KEYS + Validator::VARIANT_KEYS + Validator::PRODUCT_LIST_KEYS +
      Validator::PRODUCT_LIST_ITEM_KEYS + Validator::INVENTORY_KEYS + Validator::STOCK_KEYS
    normalized = allowed.map { |key| key.downcase.gsub(/[^a-z0-9]/, "") }

    assert_empty normalized & Validator::FORBIDDEN_KEYS
  end

  test "duplicate JSON keys are still rejected in a widened response" do
    raw = JSON.generate(product_body).sub('"productSku":"LIVE-PETBOWL"',
      '"productSku":"LIVE-PETBOWL","productSku":"LIVE-OTHER"')
    assert_malformed do
      validator.call(operation: :product, request: { "product_id" => "00001234" }, raw_body: raw,
        observed_at: OBSERVED_AT)
    end

    raw_list = JSON.generate(list_body).sub('"total":1', '"total":1,"total":2')
    assert_malformed do
      validator.call(operation: :product_list, request: list_request, raw_body: raw_list,
        observed_at: OBSERVED_AT)
    end
  end

  test "the widened sets keep the numeric bound and active content rejection" do
    over = product_body
    over["data"]["variants"].first["variantWeight"] = 99_999_999_999
    assert_malformed do
      validator.call(operation: :product, request: { "product_id" => "00001234" },
        raw_body: JSON.generate(over), observed_at: OBSERVED_AT)
    end

    active = product_body
    active["data"]["productPro"] = "<script>alert(1)</script>"
    assert_malformed do
      validator.call(operation: :product, request: { "product_id" => "00001234" },
        raw_body: JSON.generate(active), observed_at: OBSERVED_AT)
    end
  end

  test "widening the allowlists opens no socket" do
    results = refute_socket_opened do
      [ validator.call(operation: :product, request: { "product_id" => "00001234" },
          raw_body: JSON.generate(product_body), observed_at: OBSERVED_AT),
        validator.call(operation: :product_list, request: list_request,
          raw_body: JSON.generate(list_body), observed_at: OBSERVED_AT),
        validator.call(operation: :inventory, request: { "variant_id" => "00005678" },
          raw_body: JSON.generate(inventory_body), observed_at: OBSERVED_AT) ]
    end

    assert_equal %i[product product_list inventory], results.map(&:operation)
    assert results.all? { |result| result.artifact_sha256.match?(/\A[0-9a-f]{64}\z/) }
  end

  private
    def validator
      @validator ||= Validator.new
    end

    def assert_malformed(&block)
      error = assert_raises(Integrations::Cj::Error, &block)
      assert_equal :malformed_response, error.code
      refute_includes error.full_message, "SYNTHETIC-SECRET"
    end

    def list_request
      { "pageNum" => 1, "pageSize" => 20, "categoryId" => "pet-supplies", "keyword" => nil }
    end

    def product_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-product-1",
        "data" => {
          "addMarkStatus" => 0, "bigImage" => IMAGE, "categoryId" => "CAT-1", "categoryName" => "Pet Bowls",
          "createrTime" => "2026-01-02 03:04:05", "customizationJson1" => nil, "customizationJson2" => nil,
          "customizationJson3" => nil, "customizationJson4" => nil, "customizationVersion" => 0,
          "description" => "A slow feed dog bowl.", "entryCode" => "EC-1", "entryName" => "Pet bowl CN",
          "entryNameEn" => "Pet bowl", "isTestProduct" => false, "listedNum" => 12, "materialKey" => "MK-1",
          "materialKeySet" => [ "MK-1" ], "materialName" => "Plastic CN", "materialNameEn" => "Plastic",
          "materialNameEnSet" => [ "Plastic" ], "materialNameSet" => [ "Plastic CN" ], "packingKey" => "PK-1",
          "packingKeySet" => [ "PK-1" ], "packingName" => "Bag CN", "packingNameEn" => "Bag",
          "packingNameEnSet" => [ "Bag" ], "packingNameSet" => [ "Bag CN" ], "packingWeight" => 20,
          "pid" => "00001234", "productImage" => IMAGE, "productImageSet" => [ IMAGE ],
          "productKey" => "Slow feeder CN", "productKeyEn" => "Slow feeder",
          "productKeyEnSet" => [ "Slow feeder" ], "productKeySet" => [ "Slow feeder CN" ],
          "productName" => "Slow-feed dog bowl CN", "productNameEn" => "Slow-feed dog bowl",
          "productNameSet" => [ "Slow-feed dog bowl CN" ], "productPro" => "Durable",
          "productProEn" => "Durable", "productProEnSet" => [ "Durable" ], "productProSet" => [ "Durable CN" ],
          "productSku" => "LIVE-PETBOWL", "productType" => "ORDINARY_PRODUCT", "productUnit" => "piece",
          "productVideo" => nil, "productWeight" => 250, "sellPrice" => 18.99, "sourceFrom" => 1,
          "status" => "1", "suggestSellPrice" => 24.99, "supplierId" => "SUP-1",
          "supplierName" => "CJ Warehouse",
          "variants" => [ variant_row("00005678", "LIVE-PETBOWL-S"), variant_row("00005679", "LIVE-PETBOWL-L") ]
        } }
    end

    def variant_row(vid, sku)
      { "barcode" => "0123456789012", "combineNum" => 1, "combineVariants" => nil,
        "createTime" => "2026-01-02 03:04:05", "inventories" => nil, "inventoryNum" => 9, "pid" => "00001234",
        "variantHeight" => 60, "variantImage" => IMAGE, "variantKey" => "S", "variantLength" => 180,
        "variantName" => "Small CN", "variantNameEn" => "Small", "variantProperty" => nil,
        "variantSellPrice" => 18.99, "variantSku" => sku, "variantStandard" => "18x18x6",
        "variantSugSellPrice" => 24.99, "variantUnit" => "piece", "variantVolume" => 1.2,
        "variantWeight" => 250.5, "variantWidth" => 180, "vid" => vid }
    end

    def list_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-list-1",
        "data" => { "pageNum" => 1, "pageSize" => 20, "total" => 1, "list" => [ list_item ] } }
    end

    def list_item
      { "addMarkStatus" => 0, "categoryId" => "CAT-1", "categoryName" => "Pet Bowls",
        "createTime" => "2026-01-02 03:04:05", "customizationVersion" => 0, "isFreeShipping" => false,
        "isTestProduct" => false, "isVideo" => false, "listedNum" => 12, "listingCount" => 3,
        "oneCategoryId" => "C1", "oneCategoryName" => "Pet Supplies", "pid" => "00003001",
        "productImage" => IMAGE, "productName" => "Slow-feed dog bowl CN",
        "productNameEn" => "Slow-feed dog bowl", "productSku" => "LIVE-PETBOWL",
        "productType" => "ORDINARY_PRODUCT", "productUnit" => "piece", "productWeight" => 250,
        "remark" => nil, "saleStatus" => 1, "sellPrice" => 18.99,
        "shippingCountryCodes" => [ "CN", "US" ], "sourceFrom" => 1, "supplierId" => "SUP-1",
        "supplierName" => "CJ Warehouse", "threeCategoryName" => "Slow feeders", "twoCategoryId" => "C2",
        "twoCategoryName" => "Bowls" }
    end

    def inventory_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-inventory-1",
        "data" => [ { "areaEn" => "China Warehouse", "areaId" => "01", "cjInventoryNum" => 4,
          "countryCode" => "CN", "factoryInventoryNum" => 5, "storageNum" => 9, "totalInventoryNum" => 9,
          "vid" => "00005678",
          "stock" => [ { "stockId" => "{live-stock-1}", "inventory" => 4, "factoryInventory" => 5 } ] } ] }
    end

    def refute_socket_opened
      targets = [ [ TCPSocket.singleton_class, :open ], [ TCPSocket.singleton_class, :new ],
        [ Net::HTTP.singleton_class, :start ] ]
      targets.each do |owner, name|
        owner.send(:alias_method, :"original_#{name}", name)
        owner.send(:define_method, name) { |*, **, &_block| raise "a socket was opened" }
      end
      yield
    ensure
      targets&.each do |owner, name|
        owner.send(:remove_method, name)
        owner.send(:alias_method, name, :"original_#{name}")
        owner.send(:remove_method, :"original_#{name}")
      end
    end
end
