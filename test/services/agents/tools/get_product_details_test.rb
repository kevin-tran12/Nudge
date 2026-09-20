require "test_helper"

class Agents::Tools::GetProductDetailsTest < ActiveSupport::TestCase
  include TestSupport::IdentityRecords

  setup do
    clear_identity_records
    @session = create_shopping_session
  end

  teardown { clear_identity_records }

  test "returns a minimized allow-listed projection for a known product" do
    tool = Agents::Tools::GetProductDetails.new
    result = tool.call(shopping_session: @session, arguments: { "product_id" => "00001234" })

    assert result.fetch("found")
    product = result.fetch("product")
    assert_equal "00001234", product.fetch("id")
    assert_equal "Stacking storage bin", product.fetch("title")
    assert_equal %w[description id images title variants], product.keys.sort
    assert product.fetch("variants").all? { |variant| variant.keys.sort == %w[availability id price title] }
  end

  test "an unknown id returns a typed not-found result, never a guess" do
    tool = Agents::Tools::GetProductDetails.new

    error = assert_raises(Agents::Tools::Error) do
      tool.call(shopping_session: @session, arguments: { "product_id" => "does-not-exist" })
    end
    assert_equal :not_found, error.code
  end

  test "path-traversal-shaped or malformed ids fail closed as not-found rather than raising internals" do
    tool = Agents::Tools::GetProductDetails.new

    error = assert_raises(Agents::Tools::Error) do
      tool.call(shopping_session: @session, arguments: { "product_id" => "../00001234" })
    end
    assert_equal :not_found, error.code
  end

  test "rejects missing, oversized, wrong-typed, or unexpected arguments" do
    tool = Agents::Tools::GetProductDetails.new

    [ {}, { "product_id" => "" }, { "product_id" => "x" * 201 }, { "product_id" => 1234 },
      { "product_id" => "00001234", "unexpected" => true }, "not-a-hash" ].each do |arguments|
      assert_raises(Agents::Tools::Error) { tool.call(shopping_session: @session, arguments: arguments) }
    end
  end

  test "unknown price and availability are surfaced as explicitly unknown, never presented as fact" do
    reader = Catalog::FixtureProductReader.new
    tool = Agents::Tools::GetProductDetails.new(product_reader: reader)

    result = tool.call(shopping_session: @session, arguments: { "product_id" => "00001234" })
    unknown_variant = result.fetch("product").fetch("variants").find { |variant| variant.fetch("id") == "fixture-variant-unknown" }

    assert_equal({ "state" => "unknown" }, unknown_variant.fetch("price"))
    assert_equal({ "state" => "unknown" }, unknown_variant.fetch("availability"))
  end
end
