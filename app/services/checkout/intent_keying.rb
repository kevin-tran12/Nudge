require "digest"
require "json"

module Checkout
  # Derives a deterministic, content-bound key for a checkout attempt from the
  # cart and the server-recomputed line items -- never from anything supplied
  # by the browser. The same cart content always yields the same key, which is
  # what makes a duplicate begin-checkout click reuse the same intent row
  # (unique on execution_mode/cart_id/provider/intent_key) instead of creating
  # a second one.
  module IntentKeying
    module_function

    def canonical_json(cart:, line_items:, currency:)
      {
        "cart_id" => cart.id,
        "currency" => currency,
        "items" => line_items.sort_by(&:product_variant_id).map do |item|
          {
            "product_variant_id" => item.product_variant_id,
            "unit_amount_minor" => item.unit_amount_minor,
            "quantity" => item.quantity
          }
        end
      }.to_json
    end

    # 32-byte binary digest for checkout_intents.request_hash (bytea, octet_length = 32).
    def request_hash(cart:, line_items:, currency:)
      Digest::SHA256.digest(canonical_json(cart: cart, line_items: line_items, currency: currency))
    end

    # Stable text key for checkout_intents.intent_key, and reused as the Stripe
    # idempotency key so a retried/duplicate create call never opens a second
    # Checkout Session for the same cart content.
    def intent_key(cart:, line_items:, currency:)
      Digest::SHA256.hexdigest(canonical_json(cart: cart, line_items: line_items, currency: currency))
    end
  end
end
