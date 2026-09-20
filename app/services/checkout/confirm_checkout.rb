module Checkout
  # Renders the confirmation page's data. The Stripe Checkout Session id in
  # the return-URL query string is never trusted: it is attacker-controllable
  # (anyone can craft `?session_id=...`), so it is never read here. Instead,
  # the genuine session is recovered by replaying the SAME idempotent create
  # call (intent.intent_key, unchanged) that Checkout::BeginCheckout made --
  # Stripe's own idempotency guarantee is what makes that call return the
  # original session rather than a new one -- and its live status is then read
  # fresh with retrieve_checkout_session, never trusted from the (possibly
  # stale, replay-cached) create response.
  #
  # Ownership is enforced from the server-resolved shopping session against
  # the cart the intent belongs to: a forged public_id, another shopper's
  # public_id, or no session at all all fail identically with :not_found, so
  # the response never discloses whether a given id exists.
  class ConfirmCheckout
    Result = Data.define(:intent, :cart, :line_items, :total_minor, :currency, :session, :paid)

    def initialize(adapter: Integrations::Stripe::Adapter.build, clock: -> { Time.current },
      pricer: LineItemPricer.new, success_url:, cancel_url:)
      @adapter = adapter
      @clock = clock
      @pricer = pricer
      @success_url = success_url
      @cancel_url = cancel_url
    end

    def call(shopping_session:, public_id:)
      raise Error.new(:invalid_input) unless shopping_session
      raise Error.new(:not_found) unless public_id.is_a?(String) && !public_id.empty?

      intent = CheckoutIntent.find_by(public_id: public_id)
      raise Error.new(:not_found) if intent.nil?

      cart = Cart.find_by(id: intent.cart_id)
      raise Error.new(:not_found) if cart.nil? || cart.shopping_session_id != shopping_session.id

      line_items = @pricer.call(cart)
      currency = cart.currency.to_s.strip.upcase
      stripe_line_items = line_items.map { |item| { name: item.name, amount: item.unit_amount_minor, quantity: item.quantity } }

      canonical = @adapter.create_checkout_session(
        line_items: stripe_line_items,
        currency: currency.downcase,
        idempotency_key: intent.intent_key,
        success_url: @success_url.call(intent.public_id),
        cancel_url: @cancel_url.call
      )
      session = @adapter.retrieve_checkout_session(canonical.id)

      paid = paid?(session)
      mark_converted!(intent) if paid

      Result.new(
        intent: intent.reload,
        cart: cart,
        line_items: line_items,
        total_minor: line_items.sum { |item| item.unit_amount_minor * item.quantity },
        currency: currency,
        session: session,
        paid: paid
      )
    rescue Integrations::Stripe::Error
      raise Error.new(:provider_unavailable)
    end

    private
      def paid?(session)
        session.payment_status == "paid" && session.status == "complete"
      end

      def mark_converted!(intent)
        return unless %w[open blocked].include?(intent.status)

        intent.with_lock do
          next unless %w[open blocked].include?(intent.status)

          intent.update!(status: "converted", completed_at: @clock.call, blocked_reason: nil)
        end
      rescue ActiveRecord::StaleObjectError
        intent.reload
      end
  end
end
