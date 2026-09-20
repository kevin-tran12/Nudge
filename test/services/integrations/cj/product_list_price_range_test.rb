require "test_helper"

# CJ listing rows report "3.49 -- 4.78" when a product's variants are priced
# differently. A range is not a price: surfacing it as one would fabricate a
# value the provider never quoted, so it is reported as unknown instead. The
# authoritative per-variant prices come from the product detail call.
class CjProductListPriceRangeTest < ActiveSupport::TestCase
  REQUEST = { "pageNum" => 1, "pageSize" => 2, "categoryId" => "2410110339451623300", "keyword" => nil }.freeze
  OBSERVED_AT = "2026-09-20T12:00:00Z".freeze

  test "a ranged listing price is reported as unknown rather than guessed" do
    page = normalize(sell_price: "3.49 -- 4.78")
    summary = page.value.products.first

    assert_nil summary.price, "a price range must not be collapsed into a single amount"
    assert_equal "2609171015371625000", summary.external_id
  end

  test "a single listing price is still parsed" do
    summary = normalize(sell_price: "1.38").value.products.first

    assert_equal 138, summary.price.amount_minor
    assert_equal "USD", summary.price.currency
  end

  test "a range never resolves to either endpoint or a midpoint" do
    summary = normalize(sell_price: "3.49 -- 4.78").value.products.first

    assert_nil summary.price
    [ 349, 478, 413, 414 ].each do |forbidden|
      refute_equal forbidden, summary.price&.amount_minor
    end
  end

  test "a numeric price is parsed, since fixtures and the provider disagree on type" do
    # Live CJ sends sellPrice as a string; the recorded fixtures use a JSON number.
    # Both are single values and both must parse.
    summary = normalize(sell_price: 18.99).value.products.first

    assert_equal 1899, summary.price.amount_minor
  end

  test "an unparseable price string is unknown, not an error" do
    [ "", "  ", "abc", "1.2.3", "-1.00", "3,49" ].each do |value|
      assert_nil normalize(sell_price: value).value.products.first.price,
        "#{value.inspect} should be unknown"
    end
  end

  private

  def normalize(sell_price:)
    body = {
      "code" => 200, "result" => true, "message" => "Success", "requestId" => "req-1",
      "data" => {
        "pageNum" => 1, "pageSize" => 2, "total" => 466,
        "list" => [ {
          "pid" => "2609171015371625000",
          "productSku" => "CJYD3174259",
          "productNameEn" => "Rubber TPR Outdoor Chew Toy For Large And Small Dogs",
          "productImage" => "https://cf.cjdropshipping.com/quick/product/79232efe.jpg",
          "sellPrice" => sell_price
        } ]
      }
    }.to_json

    Integrations::Cj::Normalizer.new.call(
      operation: :product_list, body: body, request: REQUEST, observed_at: OBSERVED_AT
    )
  end
end
