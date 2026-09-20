require "test_helper"

class Agents::Tools::AddToCartTest < ActiveSupport::TestCase
  include TestSupport::IdentityRecords
  include TestSupport::CatalogRecords

  setup do
    clear_identity_records
    clear_catalog_records
    create_cj_supplier
    @session = create_shopping_session
  end

  teardown do
    clear_catalog_records
    clear_identity_records
  end

  test "adds the requested quantity of a known variant to the caller's own cart" do
    tool = Agents::Tools::AddToCart.new
    result = tool.call(shopping_session: @session,
      arguments: { "product_id" => "00001234", "variant_id" => "00005678", "quantity" => 2 })

    assert result.fetch("added")
    assert_equal 2, result.fetch("quantity_in_cart")
    assert_equal 2, result.fetch("cart_item_count")
    assert_equal({ "state" => "known", "amount_minor" => 2468, "currency" => "USD" }, result.fetch("cart_total"))

    snapshot = Cart::Service.new.snapshot(shopping_session: @session)
    assert_equal 2, snapshot.line_items.first.quantity
  end

  test "defaults to a quantity of one when none is given" do
    tool = Agents::Tools::AddToCart.new
    result = tool.call(shopping_session: @session,
      arguments: { "product_id" => "00001234", "variant_id" => "00005678" })

    assert_equal 1, result.fetch("quantity_in_cart")
  end

  test "an unknown variant raises a typed not-found error rather than a guess" do
    tool = Agents::Tools::AddToCart.new

    error = assert_raises(Agents::Tools::Error) do
      tool.call(shopping_session: @session,
        arguments: { "product_id" => "00001234", "variant_id" => "does-not-exist", "quantity" => 1 })
    end
    assert_equal :not_found, error.code
  end

  test "rejects a non-positive quantity" do
    tool = Agents::Tools::AddToCart.new

    error = assert_raises(Agents::Tools::Error) do
      tool.call(shopping_session: @session,
        arguments: { "product_id" => "00001234", "variant_id" => "00005678", "quantity" => 0 })
    end
    assert_equal :invalid_arguments, error.code
  end

  test "takes no session, user, or cart identifier -- a caller-supplied one is rejected" do
    tool = Agents::Tools::AddToCart.new
    other_session = create_shopping_session

    error = assert_raises(Agents::Tools::Error) do
      tool.call(shopping_session: @session, arguments: {
        "product_id" => "00001234", "variant_id" => "00005678", "quantity" => 1,
        "shopping_session_id" => other_session.public_id
      })
    end
    assert_equal :invalid_arguments, error.code
  end

  test "cannot add to another session's cart -- identity always comes from the server-resolved session" do
    tool = Agents::Tools::AddToCart.new
    other_session = create_shopping_session

    tool.call(shopping_session: @session,
      arguments: { "product_id" => "00001234", "variant_id" => "00005678", "quantity" => 1 })

    other_snapshot = Cart::Service.new.snapshot(shopping_session: other_session)
    assert_empty other_snapshot.line_items
  end

  test "a request forging a price or total is ignored -- the schema has no such field to forge" do
    tool = Agents::Tools::AddToCart.new

    error = assert_raises(Agents::Tools::Error) do
      tool.call(shopping_session: @session, arguments: {
        "product_id" => "00001234", "variant_id" => "00005678", "quantity" => 1, "amount_minor" => 1
      })
    end
    assert_equal :invalid_arguments, error.code
  end
end
