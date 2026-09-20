require "test_helper"

module Checkout
  class LineItemPricerTest < ActiveSupport::TestCase
    include TestSupport::IdentityRecords
    include TestSupport::CheckoutRecords

    setup do
      travel_to TestSupport::CheckoutRecords::REFERENCE_TIME
      clear_checkout_records
      clear_identity_records
    end

    teardown do
      clear_checkout_records
      clear_identity_records
      travel_back
    end

    test "recomputes line items from the cart's own server-cached price, not any client input" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      variant = create_product_variant(title: "Widget")
      add_cart_item(cart: cart, product_variant: variant, quantity: 3, unit_amount_minor: 500, currency: "USD")

      items = LineItemPricer.new.call(cart)

      assert_equal 1, items.size
      item = items.first
      assert_equal variant.id, item.product_variant_id
      assert_equal "Widget", item.name
      assert_equal 500, item.unit_amount_minor
      assert_equal 3, item.quantity
      assert_equal "USD", item.currency
    end

    test "an empty cart refuses with cart_empty" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)

      error = assert_raises(Error) { LineItemPricer.new.call(cart) }
      assert_equal :cart_empty, error.code
    end

    test "an unknown-price item blocks the whole checkout" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
      add_cart_item(cart: cart, product_variant: create_product_variant, quantity: 1,
        unit_amount_minor: nil, currency: nil)

      error = assert_raises(Error) { LineItemPricer.new.call(cart) }
      assert_equal :unknown_price, error.code
    end

    test "a currency that does not match the cart's currency is refused" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session, currency: "USD")
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "EUR")

      error = assert_raises(Error) { LineItemPricer.new.call(cart) }
      assert_equal :currency_mismatch, error.code
    end
  end
end
