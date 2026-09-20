require "test_helper"
require "net/http"
require "digest"

module Checkout
  class ConfirmCheckoutTest < ActiveSupport::TestCase
    include TestSupport::IdentityRecords
    include TestSupport::CheckoutRecords

    class FakeAdapter
      attr_reader :mode, :create_calls

      def initialize(payment_status:, status:, mode: :fixture)
        @mode = mode
        @payment_status = payment_status
        @status = status
        @create_calls = []
      end

      def create_checkout_session(line_items:, currency:, idempotency_key:, success_url: nil, cancel_url: nil)
        @create_calls << idempotency_key
        id = "cs_test_fake_#{Digest::SHA256.hexdigest(idempotency_key)[0, 24]}"
        Integrations::Stripe::Adapter::Result.new(
          id: id, url: "https://checkout.stripe.test/fake/#{id}", status: "open",
          currency: currency, amount_total: line_items.sum { |item| item[:amount] * item[:quantity] },
          payment_status: "unpaid"
        )
      end

      def retrieve_checkout_session(id)
        Integrations::Stripe::Adapter::Result.new(
          id: id, url: nil, status: @status, currency: "usd", amount_total: nil, payment_status: @payment_status
        )
      end
    end

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

    def urls
      { success_url: ->(public_id) { "https://shop.example.test/checkout/#{public_id}" },
        cancel_url: -> { "https://shop.example.test/products" } }
    end

    def begin_intent(session:, cart:)
      BeginCheckout.new(**urls).call(shopping_session: session).intent_public_id
    end

    test "an unpaid or incomplete Stripe session never renders as confirmed" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
      public_id = begin_intent(session: session, cart: cart)

      result = ConfirmCheckout.new(**urls).call(shopping_session: session, public_id: public_id)

      refute result.paid
      assert_equal "open", CheckoutIntent.find_by!(public_id: public_id).status
    end

    test "a genuinely paid and complete Stripe session renders confirmed and converts the intent" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 2, unit_amount_minor: 500, currency: "USD")
      public_id = begin_intent(session: session, cart: cart)

      adapter = FakeAdapter.new(payment_status: "paid", status: "complete")
      result = ConfirmCheckout.new(adapter: adapter, **urls).call(shopping_session: session, public_id: public_id)

      assert result.paid
      intent = CheckoutIntent.find_by!(public_id: public_id)
      assert_equal "converted", intent.status
      assert intent.completed_at.present?
      assert_equal 1_000, result.total_minor
    end

    test "revisiting a confirmed checkout stays converted without erroring" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
      public_id = begin_intent(session: session, cart: cart)
      adapter = FakeAdapter.new(payment_status: "paid", status: "complete")

      ConfirmCheckout.new(adapter: adapter, **urls).call(shopping_session: session, public_id: public_id)
      result = ConfirmCheckout.new(adapter: adapter, **urls).call(shopping_session: session, public_id: public_id)

      assert result.paid
      assert_equal "converted", CheckoutIntent.find_by!(public_id: public_id).status
    end

    test "a forged public_id is treated exactly like a missing one" do
      session = create_shopping_session

      error = assert_raises(Error) { ConfirmCheckout.new(**urls).call(shopping_session: session, public_id: "not-a-real-id") }
      assert_equal :not_found, error.code
    end

    test "another shopper's checkout is not visible: cross-session isolation" do
      owner = create_shopping_session
      owner_cart = create_cart(shopping_session: owner)
      add_cart_item(cart: owner_cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
      public_id = begin_intent(session: owner, cart: owner_cart)

      intruder = create_shopping_session

      error = assert_raises(Error) { ConfirmCheckout.new(**urls).call(shopping_session: intruder, public_id: public_id) }
      assert_equal :not_found, error.code
    end

    test "the service takes no session_id parameter at all: the query string is never trusted" do
      assert_equal [ [ :keyreq, :shopping_session ], [ :keyreq, :public_id ] ],
        ConfirmCheckout.new(**urls).method(:call).parameters
    end

    test "makes zero live network calls in fixture mode" do
      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
      public_id = begin_intent(session: session, cart: cart)

      original = Net::HTTP.method(:start)
      Net::HTTP.define_singleton_method(:start) { |*| raise "ConfirmCheckout attempted a live HTTP call" }
      result = ConfirmCheckout.new(**urls).call(shopping_session: session, public_id: public_id)
      refute result.paid
    ensure
      Net::HTTP.define_singleton_method(:start, original) if original
    end
  end
end
