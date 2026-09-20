require "net/http"
require "socket"

module TestSupport
  # CJ-LIVE-IMPORT-01. The shape CJ actually returns, trimmed but faithful,
  # transcribed from live authenticated calls on 2026-09-20. It keeps the
  # details that every earlier hand-sanitized fixture had quietly dropped and
  # that each broke the import in turn:
  #
  #   * descriptions and list remarks are attribute-bearing marketing HTML
  #     (<img src=...>, <br/>, <b>, style="max-width:100%");
  #   * createTime is a millisecond epoch, not a formatted timestamp;
  #   * every envelope carries pointsInfo and success;
  #   * sellPrice and productWeight are strings, and a list row's sellPrice is
  #     a hyphenated range rather than a single number.
  #
  # Every byte here is a literal, so anything built from it is offline.
  module CjLiveResponseShapes
    LIVE_IMAGE = "https://oss-cf.cjdropshipping.com/product/2026/09/16/11/" \
      "bf27dfbe-947f-42aa-afa7-b41d3ec285f8_trans.jpeg".freeze
    LIVE_VARIANT_IMAGE = "https://oss-cf.cjdropshipping.com/product/2026/09/16/11/" \
      "89c89f3f-7dba-48ec-860c-c960438809dc_trans.jpeg".freeze
    LIVE_PRODUCT_ID = "2609161110071617400".freeze
    LIVE_VARIANT_ID = "2609161110071618400".freeze
    LIVE_SECOND_VARIANT_ID = "2609161110071618401".freeze
    LIVE_LIST_PRODUCT_ID = "2609171015001340200".freeze

    LIVE_DESCRIPTION = <<~HTML.freeze
      <p><b>Product information:</b><br/>Color: Blue tennis style<br/> Material: TPR<br/> Shape: Candy</p>
      <br/>
      <b>Product Image:</b>
      <br/>
      <img src="#{LIVE_IMAGE}"/>
      <img src="#{LIVE_IMAGE}" style="max-width:100%;" alt="Dog toy" width="750" height="750" class="detail" title="Front"/>
      <p><a href="https://cjdropshipping.com/product/2609161110071617400">Supplier listing</a></p>
    HTML

    LIVE_REMARK = %(<p><img src="#{LIVE_IMAGE}"/></p>).freeze

    def live_points_info
      { "total" => 50_000, "usedToday" => 360, "remaining" => 50_000 }
    end

    def live_product_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-product-1",
        "success" => true, "pointsInfo" => live_points_info,
        "data" => {
          "addMarkStatus" => 0, "bigImage" => LIVE_IMAGE, "categoryId" => "2410110339451623300",
          "categoryName" => "Dog Toys", "createrTime" => "2026-09-16 11:10:07", "customizationJson1" => nil,
          "customizationJson2" => nil, "customizationJson3" => nil, "customizationJson4" => nil,
          "customizationVersion" => 0, "description" => LIVE_DESCRIPTION, "entryCode" => "EC-1",
          "entryName" => "Pet toy CN", "entryNameEn" => "Pet toy", "isTestProduct" => false, "listedNum" => 0,
          "materialKey" => "TPR", "materialKeySet" => [ "TPR" ], "materialName" => "TPR",
          "materialNameEn" => "TPR", "materialNameEnSet" => [ "TPR" ], "materialNameSet" => [ "TPR" ],
          "packingKey" => "OPP", "packingKeySet" => [ "OPP" ], "packingName" => "OPP bag CN",
          "packingNameEn" => "OPP bag", "packingNameEnSet" => [ "OPP bag" ],
          "packingNameSet" => [ "OPP bag CN" ], "packingWeight" => 5, "pid" => LIVE_PRODUCT_ID,
          "productImage" => LIVE_IMAGE, "productImageSet" => [ LIVE_IMAGE, LIVE_VARIANT_IMAGE ],
          "productKey" => "Dog toy CN", "productKeyEn" => "Dog toy", "productKeyEnSet" => [ "Dog toy" ],
          "productKeySet" => [ "Dog toy CN" ], "productName" => "Dog Toy Candy Tennis Ball Glowing CN",
          "productNameEn" => "Dog Toy Candy Tennis Ball Glowing",
          "productNameSet" => [ "Dog Toy Candy Tennis Ball Glowing CN" ], "productPro" => "Durable",
          "productProEn" => "Durable", "productProEnSet" => [ "Durable" ], "productProSet" => [ "Durable CN" ],
          "productSku" => "CJYD3170983", "productType" => "ORDINARY_PRODUCT", "productUnit" => "piece",
          "productVideo" => nil, "productWeight" => "74.00-99.00", "sellPrice" => "1.38", "sourceFrom" => 1,
          "status" => "1", "suggestSellPrice" => "6.45", "supplierId" => "SUP-1",
          "supplierName" => "CJ Warehouse",
          "variants" => [ live_variant_row(LIVE_VARIANT_ID, "CJYD317098302BY"),
            live_variant_row(LIVE_SECOND_VARIANT_ID, "CJYD317098302YE") ]
        } }
    end

    def live_variant_row(vid, sku)
      { "barcode" => nil, "combineNum" => 1, "combineVariants" => nil, "createTime" => 1_789_557_007_000,
        "inventories" => nil, "inventoryNum" => 0, "pid" => LIVE_PRODUCT_ID, "variantHeight" => 60,
        "variantImage" => LIVE_VARIANT_IMAGE, "variantKey" => "Blue-Luminous", "variantLength" => 80,
        "variantName" => "Blue Luminous CN",
        "variantNameEn" => "Dog Toy Candy Tennis Ball Glowing Blue Luminous Style",
        "variantProperty" => nil, "variantSellPrice" => 1.38, "variantSku" => sku,
        "variantStandard" => "8*6*6", "variantSugSellPrice" => 6.45, "variantUnit" => "piece",
        "variantVolume" => 0.29, "variantWeight" => 74.0, "variantWidth" => 60, "vid" => vid }
    end

    def live_list_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-list-1",
        "success" => true, "pointsInfo" => live_points_info,
        "data" => { "pageNum" => 1, "pageSize" => 3, "total" => 466, "list" => [ live_list_item ] } }
    end

    def live_list_item
      { "addMarkStatus" => 0, "categoryId" => "2410110339451623300", "categoryName" => "Dog Toys",
        "createTime" => 1_789_640_137_000, "customizationVersion" => 0, "isFreeShipping" => false,
        "isTestProduct" => false, "isVideo" => true, "listedNum" => 0, "listingCount" => 0,
        "oneCategoryId" => "C1", "oneCategoryName" => "Pet Supplies", "pid" => LIVE_LIST_PRODUCT_ID,
        "productImage" => LIVE_IMAGE, "productName" => "Rubber TPR Outdoor Chew Toy CN",
        "productNameEn" => "Rubber TPR Outdoor Chew Toy For Large And Small Dogs",
        "productSku" => "CJYD3171402", "productType" => "ORDINARY_PRODUCT", "productUnit" => "piece",
        "productWeight" => "35.00-120.00", "remark" => LIVE_REMARK, "saleStatus" => 1,
        "sellPrice" => "3.49 -- 4.78", "shippingCountryCodes" => [ "CN", "US" ], "sourceFrom" => 1,
        "supplierId" => "SUP-1", "supplierName" => "CJ Warehouse", "threeCategoryName" => "Chew Toys",
        "twoCategoryId" => "C2", "twoCategoryName" => "Toys" }
    end

    def live_list_request
      { "pageNum" => 1, "pageSize" => 3, "categoryId" => "2410110339451623300", "keyword" => nil }
    end

    def live_inventory_body
      { "code" => 200, "result" => true, "message" => "Success", "requestId" => "live-inventory-1",
        "success" => true, "pointsInfo" => live_points_info,
        "data" => [ { "areaEn" => "China Warehouse", "areaId" => "1", "cjInventoryNum" => 0,
          "countryCode" => "CN", "factoryInventoryNum" => 5675, "storageNum" => 5675,
          "totalInventoryNum" => 5675, "vid" => LIVE_VARIANT_ID,
          "stock" => [ { "stockId" => "{6709CCD7-0DC7-43B1-B310-17AB499E9B0A}", "inventory" => 0,
            "factoryInventory" => 5675 } ] } ] }
    end

    # Asserts the block opens no socket. Every CJ artifact path is offline by
    # construction and must stay that way in ordinary `bin/rails test` and CI.
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
end
