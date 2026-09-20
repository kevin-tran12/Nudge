# Owns exactly the last two steps of the vertical slice: starting a Stripe
# test-mode Checkout Session for the current shopper's cart, and rendering
# the confirmation page from Stripe's own (re-verified) session status. No
# order domain, no receipts, no webhook handling -- see AGENTS.md and the
# CHECKOUT-01 report for what is deliberately out of scope.
class CheckoutController < ApplicationController
  ERROR_COPY = {
    invalid_input: [ "Checkout unavailable", "Something went wrong starting checkout. Please try again." ],
    cart_not_found: [ "Your cart is empty", "Add an item to your cart before checking out." ],
    cart_empty: [ "Your cart is empty", "Add an item to your cart before checking out." ],
    unknown_price: [ "Price not confirmed yet", "One or more items in your cart do not have a confirmed price. Remove or refresh that item before checking out." ],
    currency_mismatch: [ "Cart currency mismatch", "Your cart mixes currencies, so a total cannot be computed. Please start a new cart." ],
    conflict: [ "Checkout unavailable", "This checkout can no longer be completed. Start a new checkout from your cart." ],
    provider_unavailable: [ "Checkout temporarily unavailable", "Please try again in a moment." ],
    not_found: [ "Checkout not found", "We couldn't find that checkout for your session." ]
  }.freeze

  def new
    @cart = current_shopping_session && Cart.find_by(shopping_session_id: current_shopping_session.id, status: "active")
    @line_items = @cart ? Checkout::LineItemPricer.new.call(@cart) : nil
    @total_minor = @line_items&.sum { |item| item.unit_amount_minor * item.quantity }
    @currency = @cart&.currency
  rescue Checkout::Error => error
    render_checkout_error(error.code)
  end

  def create
    result = begin_checkout_service.call(shopping_session: authorized_shopping_session)
    redirect_to result.redirect_url, allow_other_host: true
  rescue Checkout::Error => error
    render_checkout_error(error.code)
  end

  def show
    result = confirm_checkout_service.call(shopping_session: authorized_shopping_session, public_id: params[:public_id])
    @intent = result.intent
    @cart = result.cart
    @line_items = result.line_items
    @total_minor = result.total_minor
    @currency = result.currency
    @session = result.session
    @paid = result.paid
  rescue Checkout::Error => error
    render_checkout_error(error.code, status: error.code == :not_found ? :not_found : :unprocessable_entity)
  end

  private
    def authorized_shopping_session
      current_shopping_session || raise(Checkout::Error.new(:invalid_input))
    end

    def begin_checkout_service
      Checkout::BeginCheckout.new(
        success_url: ->(public_id) { checkout_confirmation_url(public_id) },
        cancel_url: -> { products_url }
      )
    end

    def confirm_checkout_service
      Checkout::ConfirmCheckout.new(
        success_url: ->(public_id) { checkout_confirmation_url(public_id) },
        cancel_url: -> { products_url }
      )
    end

    def render_checkout_error(code, status: :unprocessable_entity)
      @error_title, @error_message = ERROR_COPY.fetch(code, ERROR_COPY[:invalid_input])
      render "checkout/error", status: status
    end
end
