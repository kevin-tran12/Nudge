module Checkout
  # Begins a Stripe test-mode Checkout Session for the current shopper's
  # active cart. Never trusts anything from the browser for pricing: totals
  # come only from Checkout::LineItemPricer, which reads server-resident cart
  # data. Idempotent: a duplicate click with an unchanged cart reuses the same
  # checkout_intents row and the same Stripe Checkout Session rather than
  # creating a second one (see Checkout::IntentKeying).
  class BeginCheckout
    INTENT_TTL = 30.minutes

    Result = Data.define(:redirect_url, :intent_public_id)

    def initialize(adapter: Integrations::Stripe::Adapter.build, clock: -> { Time.current },
      pricer: LineItemPricer.new, success_url:, cancel_url:)
      @adapter = adapter
      @clock = clock
      @pricer = pricer
      @success_url = success_url
      @cancel_url = cancel_url
    end

    def call(shopping_session:)
      raise Error.new(:invalid_input) unless shopping_session

      cart = active_cart_for(shopping_session)
      raise Error.new(:cart_not_found) if cart.nil?

      line_items = @pricer.call(cart)
      currency = cart.currency.to_s.strip.upcase
      intent = find_or_create_intent(cart: cart, line_items: line_items, currency: currency)

      case intent.status
      when "converted"
        return Result.new(redirect_url: @success_url.call(intent.public_id), intent_public_id: intent.public_id)
      when "expired", "cancelled", "blocked"
        # Cancellation/expiry recovery policy is an open canonical decision
        # (see AGENTS.md "Payments and consequential operations"). Rather than
        # inventing one, this refuses cleanly and leaves the existing row
        # exactly as it is.
        raise Error.new(:conflict)
      end

      stripe_line_items = line_items.map { |item| { name: item.name, amount: item.unit_amount_minor, quantity: item.quantity } }
      session = @adapter.create_checkout_session(
        line_items: stripe_line_items,
        currency: currency.downcase,
        idempotency_key: intent.intent_key,
        success_url: @success_url.call(intent.public_id),
        cancel_url: @cancel_url.call
      )

      Result.new(redirect_url: session.url, intent_public_id: intent.public_id)
    rescue Integrations::Stripe::Error
      raise Error.new(:provider_unavailable)
    end

    private
      def active_cart_for(shopping_session)
        Cart.find_by(shopping_session_id: shopping_session.id, status: "active")
      end

      def find_or_create_intent(cart:, line_items:, currency:)
        execution_mode = @adapter.mode == :fixture ? "fixture" : "sandbox"
        intent_key = IntentKeying.intent_key(cart: cart, line_items: line_items, currency: currency)
        request_hash = IntentKeying.request_hash(cart: cart, line_items: line_items, currency: currency)

        existing = CheckoutIntent.find_by(
          execution_mode: execution_mode, cart_id: cart.id, provider: CheckoutIntent::PROVIDER, intent_key: intent_key
        )
        return existing if existing

        now = @clock.call
        CheckoutIntent.create!(
          execution_mode: execution_mode, cart_id: cart.id, provider: CheckoutIntent::PROVIDER,
          intent_key: intent_key, request_hash: request_hash, status: "open",
          started_at: now, expires_at: now + INTENT_TTL
        )
      rescue ActiveRecord::RecordNotUnique
        CheckoutIntent.find_by!(
          execution_mode: execution_mode, cart_id: cart.id, provider: CheckoutIntent::PROVIDER, intent_key: intent_key
        )
      end
  end
end
