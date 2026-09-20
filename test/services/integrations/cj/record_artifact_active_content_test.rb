require "test_helper"
require "json"
require "net/http"
require "socket"

# CJ-LIVE-IMPORT-01. reject_active_content! used to refuse any HTML element
# carrying any attribute at all. Real CJ product descriptions and list remarks
# are ordinary marketing HTML built from <img src=...>, <br/>, <b> and
# style="max-width:100%", so that blanket rule made every genuine product
# unstorable. The rule now rejects only what can execute or exfiltrate:
# on* handlers, dangerous URL schemes in any attribute value, and the
# srcdoc/formaction/xlink:href navigation vectors. Active *elements* are
# rejected exactly as before.
#
# Entirely offline: every byte here is a literal in this file.
class CjRecordArtifactActiveContentTest < ActiveSupport::TestCase
  OBSERVED_AT = "2026-09-20T00:00:00Z".freeze
  IMAGE = "https://oss-cf.cjdropshipping.com/product/2026/09/16/11/bf27dfbe-947f-42aa-afa7-b41d3ec285f8_trans.jpeg".freeze
  Validator = Integrations::Cj::RecordArtifactValidator

  # The shape CJ actually returns, trimmed but faithful: an attribute-bearing
  # marketing description, a millisecond epoch createTime, the pointsInfo and
  # success envelope keys, and a hyphenated sellPrice range on the list rows.
  LIVE_DESCRIPTION = <<~HTML.freeze
    <p><b>Product information:</b><br/>Color: Blue tennis style<br/> Material: TPR<br/> Shape: Candy</p>
    <br/>
    <b>Product Image:</b>
    <br/>
    <img src="#{IMAGE}"/>
    <img src="#{IMAGE}" style="max-width:100%;" alt="Dog toy" width="750" height="750" class="detail" title="Front"/>
    <p><a href="https://cjdropshipping.com/product/2609161110071617400">Supplier listing</a></p>
  HTML

  LIVE_REMARK = %(<p><img src="#{IMAGE}"/></p>).freeze

  # --- the rule itself -----------------------------------------------------

  test "a presentational img inside a description validates" do
    fragment = %(<img src="https://oss-cf.cjdropshipping.com/x.jpg" style="max-width:100%">)

    result = validate_product(description: fragment)

    assert_equal :product, result.operation
  end

  test "every benign presentational attribute real supplier HTML uses is permitted" do
    %w[src alt width height style class title].each do |attribute|
      result = validate_product(description: %(<img src="#{IMAGE}" #{attribute}="10"/>))

      assert_equal :product, result.operation, "#{attribute} should be permitted"
    end
  end

  test "an href to an ordinary http or https URL is permitted" do
    [ "https://cjdropshipping.com/p/1", "http://cjdropshipping.com/p/1", "/p/1", "#anchor" ].each do |href|
      result = validate_product(description: %(<a href="#{href}">Listing</a>))

      assert_equal :product, result.operation, "#{href} should be permitted"
    end
  end

  test "active elements are still rejected" do
    %w[script style template iframe object].each do |element|
      assert_malformed("<#{element}> should be rejected") do
        validate_product(description: "<p>Safe</p><#{element}>SYNTHETIC-SECRET</#{element}>")
      end
    end
  end

  test "any event handler attribute is rejected" do
    %w[onclick onerror onload onmouseover ONCLICK OnError onfocusin].each do |attribute|
      assert_malformed("#{attribute} should be rejected") do
        validate_product(description: %(<img src="#{IMAGE}" #{attribute}="SYNTHETIC-SECRET"/>))
      end
    end
  end

  test "a dangerous URL scheme in any attribute value is rejected" do
    [ "javascript:alert(1)",
      "JaVaScRiPt:alert(1)",
      "java\tscript:alert(1)",
      "java\nscript:alert(1)",
      "java\rscript:alert(1)",
      "  javascript:alert(1)",
      "vbscript:msgbox(1)",
      "VBScript:msgbox(1)",
      "data:text/html;base64,U1lOVEhFVElD" ].each do |value|
      assert_malformed("href=#{value.inspect} should be rejected") do
        validate_product(description: %(<a href="#{value}">x</a>))
      end

      assert_malformed("src=#{value.inspect} should be rejected") do
        validate_product(description: %(<img src="#{value}"/>))
      end
    end
  end

  test "an html entity encoded dangerous scheme is rejected" do
    [ "&#106;avascript:alert(1)", "java&#9;script:alert(1)", "&#74;avaScript:alert(1)" ].each do |value|
      assert_malformed("href=#{value.inspect} should be rejected") do
        validate_product(description: %(<a href="#{value}">x</a>))
      end
    end
  end

  test "the srcdoc formaction and xlink href navigation vectors are rejected" do
    [ %(<div srcdoc="anything"></div>),
      %(<button formaction="https://example.com/steal">x</button>),
      %(<a xlink:href="https://example.com/steal">x</a>),
      %(<svg><a xlink:href="https://example.com/steal">x</a></svg>) ].each do |fragment|
      assert_malformed("#{fragment} should be rejected") do
        validate_product(description: fragment)
      end
    end
  end

  test "a dangerous scheme is rejected wherever it hides not only in the description" do
    assert_malformed do
      validate_product(product_pro: %(<b title="javascript:alert(1)">x</b>))
    end

    body = list_body
    body["data"]["list"].first["remark"] = %(<img src="#{IMAGE}" onerror="alert(1)"/>)
    assert_malformed do
      validator.call(operation: :product_list, request: list_request, raw_body: JSON.generate(body),
        observed_at: OBSERVED_AT)
    end
  end

  test "a colon that is not a scheme does not look dangerous" do
    [ "Ratio data : 3", "Note: javascript is not used here", "Style data" ].each do |text|
      result = validate_product(description: %(<b title="#{text}">x</b>))

      assert_equal :product, result.operation, "#{text.inspect} should be permitted"
    end
  end

  # --- the three real response shapes --------------------------------------

  test "a realistic live product response with attribute bearing HTML validates" do
    result = validator.call(operation: :product, request: { "product_id" => "2609161110071617400" },
      raw_body: JSON.generate(product_body), observed_at: OBSERVED_AT)

    assert_equal "2609161110071617400", result.normalized.value.external_id
    assert_equal %w[2609161110071618400 2609161110071618401], result.normalized.value.variants.map(&:external_id)
    assert_includes result.artifact_bytes, "oss-cf.cjdropshipping.com"
  end

  test "a realistic live product list response with HTML remarks and a price range validates" do
    body = list_body
    assert_equal "3.49 -- 4.78", body.dig("data", "list").first.fetch("sellPrice")

    result = validator.call(operation: :product_list, request: list_request, raw_body: JSON.generate(body),
      observed_at: OBSERVED_AT)

    assert_equal %w[2609171015001340200], result.normalized.value.products.map(&:external_id)
  end

  test "a realistic live inventory response validates" do
    result = validator.call(operation: :inventory, request: { "variant_id" => "2609161110071618400" },
      raw_body: JSON.generate(inventory_body), observed_at: OBSERVED_AT)

    assert_equal [ "2609161110071618400" ], result.normalized.value.map(&:variant_id)
  end

  test "the live envelope keys and the millisecond createTime are accepted" do
    body = product_body
    assert_equal 1_789_557_007_000, body.dig("data", "variants").first.fetch("createTime")
    assert_equal %w[code data message pointsInfo requestId result success], body.keys.sort

    assert_equal :product, validator.call(operation: :product, request: { "product_id" => "2609161110071617400" },
      raw_body: JSON.generate(body), observed_at: OBSERVED_AT).operation
  end

  test "the relaxed attribute rule opens no socket" do
    results = refute_socket_opened do
      [ validator.call(operation: :product, request: { "product_id" => "2609161110071617400" },
          raw_body: JSON.generate(product_body), observed_at: OBSERVED_AT),
        validator.call(operation: :product_list, request: list_request, raw_body: JSON.generate(list_body),
          observed_at: OBSERVED_AT),
        validator.call(operation: :inventory, request: { "variant_id" => "2609161110071618400" },
          raw_body: JSON.generate(inventory_body), observed_at: OBSERVED_AT) ]
    end

    assert_equal %i[product product_list inventory], results.map(&:operation)
  end

  private
    def validator
      @validator ||= Validator.new
    end

    def assert_malformed(message = nil, &block)
      args = [ Integrations::Cj::Error, message ].compact
      error = assert_raises(*args, &block)
      assert_equal :malformed_response, error.code, message
      refute_includes error.full_message, "SYNTHETIC-SECRET"
    end

    def validate_product(description: LIVE_DESCRIPTION, product_pro: "Durable")
      body = product_body
      body["data"]["description"] = description
      body["data"]["productPro"] = product_pro
      validator.call(operation: :product, request: { "product_id" => "2609161110071617400" },
        raw_body: JSON.generate(body), observed_at: OBSERVED_AT)
    end

    def list_request
      { "pageNum" => 1, "pageSize" => 3, "categoryId" => "2410110339451623300", "keyword" => nil }
    end

    def points_info
      { "total" => 50_000, "usedToday" => 360, "remaining" => 50_000 }
    end

    def product_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-product-1",
        "success" => true, "pointsInfo" => points_info,
        "data" => {
          "addMarkStatus" => 0, "bigImage" => IMAGE, "categoryId" => "2410110339451623300",
          "categoryName" => "Dog Toys", "createrTime" => "2026-09-16 11:10:07", "customizationJson1" => nil,
          "customizationJson2" => nil, "customizationJson3" => nil, "customizationJson4" => nil,
          "customizationVersion" => 0, "description" => LIVE_DESCRIPTION, "entryCode" => "EC-1",
          "entryName" => "Pet toy CN", "entryNameEn" => "Pet toy", "isTestProduct" => false, "listedNum" => 0,
          "materialKey" => "TPR", "materialKeySet" => [ "TPR" ], "materialName" => "TPR",
          "materialNameEn" => "TPR", "materialNameEnSet" => [ "TPR" ], "materialNameSet" => [ "TPR" ],
          "packingKey" => "OPP", "packingKeySet" => [ "OPP" ], "packingName" => "OPP bag CN",
          "packingNameEn" => "OPP bag", "packingNameEnSet" => [ "OPP bag" ], "packingNameSet" => [ "OPP bag CN" ],
          "packingWeight" => 5, "pid" => "2609161110071617400", "productImage" => IMAGE,
          "productImageSet" => [ IMAGE ], "productKey" => "Dog toy CN", "productKeyEn" => "Dog toy",
          "productKeyEnSet" => [ "Dog toy" ], "productKeySet" => [ "Dog toy CN" ],
          "productName" => "Dog Toy Candy Tennis Ball Glowing CN",
          "productNameEn" => "Dog Toy Candy Tennis Ball Glowing",
          "productNameSet" => [ "Dog Toy Candy Tennis Ball Glowing CN" ], "productPro" => "Durable",
          "productProEn" => "Durable", "productProEnSet" => [ "Durable" ], "productProSet" => [ "Durable CN" ],
          "productSku" => "CJYD3170983", "productType" => "ORDINARY_PRODUCT", "productUnit" => "piece",
          "productVideo" => nil, "productWeight" => "74.00-99.00", "sellPrice" => "1.38", "sourceFrom" => 1,
          "status" => "1", "suggestSellPrice" => "6.45", "supplierId" => "SUP-1",
          "supplierName" => "CJ Warehouse",
          "variants" => [ variant_row("2609161110071618400", "CJYD317098302BY"),
            variant_row("2609161110071618401", "CJYD317098302YE") ]
        } }
    end

    def variant_row(vid, sku)
      { "barcode" => nil, "combineNum" => 1, "combineVariants" => nil, "createTime" => 1_789_557_007_000,
        "inventories" => nil, "inventoryNum" => 0, "pid" => "2609161110071617400", "variantHeight" => 60,
        "variantImage" => IMAGE, "variantKey" => "Blue-Luminous", "variantLength" => 80,
        "variantName" => "Blue Luminous CN",
        "variantNameEn" => "Dog Toy Candy Tennis Ball Glowing Blue Luminous Style",
        "variantProperty" => nil, "variantSellPrice" => 1.38, "variantSku" => sku,
        "variantStandard" => "8*6*6", "variantSugSellPrice" => 6.45, "variantUnit" => "piece",
        "variantVolume" => 0.29, "variantWeight" => 74.0, "variantWidth" => 60, "vid" => vid }
    end

    def list_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-list-1",
        "success" => true, "pointsInfo" => points_info,
        "data" => { "pageNum" => 1, "pageSize" => 3, "total" => 466, "list" => [ list_item ] } }
    end

    def list_item
      { "addMarkStatus" => 0, "categoryId" => "2410110339451623300", "categoryName" => "Dog Toys",
        "createTime" => 1_789_640_137_000, "customizationVersion" => 0, "isFreeShipping" => false,
        "isTestProduct" => false, "isVideo" => true, "listedNum" => 0, "listingCount" => 0,
        "oneCategoryId" => "C1", "oneCategoryName" => "Pet Supplies", "pid" => "2609171015001340200",
        "productImage" => IMAGE, "productName" => "Rubber TPR Outdoor Chew Toy CN",
        "productNameEn" => "Rubber TPR Outdoor Chew Toy For Large And Small Dogs",
        "productSku" => "CJYD3171402", "productType" => "ORDINARY_PRODUCT", "productUnit" => "piece",
        "productWeight" => "35.00-120.00", "remark" => LIVE_REMARK, "saleStatus" => 1,
        "sellPrice" => "3.49 -- 4.78", "shippingCountryCodes" => [ "CN", "US" ], "sourceFrom" => 1,
        "supplierId" => "SUP-1", "supplierName" => "CJ Warehouse", "threeCategoryName" => "Chew Toys",
        "twoCategoryId" => "C2", "twoCategoryName" => "Toys" }
    end

    def inventory_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-inventory-1",
        "success" => true, "pointsInfo" => points_info,
        "data" => [ { "areaEn" => "China Warehouse", "areaId" => "1", "cjInventoryNum" => 0,
          "countryCode" => "CN", "factoryInventoryNum" => 5675, "storageNum" => 5675,
          "totalInventoryNum" => 5675, "vid" => "2609161110071618400",
          "stock" => [ { "stockId" => "{6709CCD7-0DC7-43B1-B310-17AB499E9B0A}", "inventory" => 0,
            "factoryInventory" => 5675 } ] } ] }
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
