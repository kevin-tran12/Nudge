require "test_helper"
require "net/http"

module Checkout
  class BeginCheckoutTest < ActiveSupport::TestCase
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

    def service
      BeginCheckout.new(
        success_url: ->(public_id) { "https://shop.example.test/checkout/#{public_id}" },
        cancel_url: -> { "https://shop.example.test/products" }
      )
    end

    test "starts a fixture-mode Stripe Checkout Session for the current session's active cart" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 2, unit_amount_minor: 500, currency: "USD")

      result = service.call(shopping_session: session)

      intent = CheckoutIntent.find_by!(public_id: result.intent_public_id)
      assert_equal "fixture", intent.execution_mode
      assert_equal "stripe", intent.provider
      assert_equal cart.id, intent.cart_id
      assert_equal "open", intent.status
      assert result.redirect_url.present?
    end

    test "a duplicate begin-checkout click does not create a second intent or a second Stripe session" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 2, unit_amount_minor: 500, currency: "USD")

      assert_difference -> { CheckoutIntent.count }, 1 do
        first = service.call(shopping_session: session)
        second = service.call(shopping_session: session)
        assert_equal first.intent_public_id, second.intent_public_id
        assert_equal first.redirect_url, second.redirect_url
      end
    end

    test "changing the cart before a second click opens a fresh intent instead of reusing the stale one" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")

      first = service.call(shopping_session: session)
      add_cart_item(cart: cart, product_variant: create_product_variant, quantity: 1, unit_amount_minor: 999, currency: "USD")
      second = service.call(shopping_session: session)

      assert_not_equal first.intent_public_id, second.intent_public_id
      assert_equal 2, CheckoutIntent.count
    end

    test "an empty cart refuses checkout" do
      session = create_shopping_session
      create_cart(shopping_session: session)

      error = assert_raises(Error) { service.call(shopping_session: session) }
      assert_equal :cart_empty, error.code
    end

    test "no active cart at all refuses checkout" do
      session = create_shopping_session

      error = assert_raises(Error) { service.call(shopping_session: session) }
      assert_equal :cart_not_found, error.code
    end

    test "an unknown-price item refuses checkout with a clear reason" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: nil, currency: nil)

      error = assert_raises(Error) { service.call(shopping_session: session) }
      assert_equal :unknown_price, error.code
    end

    test "one session cannot begin checkout for another session's cart" do
      owner = create_shopping_session
      owner_cart = create_cart(shopping_session: owner)
      add_cart_item(cart: owner_cart, quantity: 1, unit_amount_minor: 500, currency: "USD")

      other = create_shopping_session

      error = assert_raises(Error) { service.call(shopping_session: other) }
      assert_equal :cart_not_found, error.code
    end

    test "a forged client total is never consulted: totals come only from the cart" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 2, unit_amount_minor: 500, currency: "USD")

      # BeginCheckout#call accepts only shopping_session:; there is no price,
      # quantity, or total parameter for a caller to forge in the first place.
      assert_equal [ [ :keyreq, :shopping_session ] ], service.method(:call).parameters
    end

    test "makes zero live network calls in fixture mode" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
      original = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) { |*| raise "BeginCheckout attempted a live HTTP call" }

      service.call(shopping_session: session)
    ensure
      Net::HTTP.define_singleton_method(:start, original) if original
    end
  end
end
