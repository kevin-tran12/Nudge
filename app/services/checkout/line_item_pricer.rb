module Checkout
  # Recomputes checkout line items strictly from server-resident, catalog-derived
  # data on the cart -- never from any client-supplied price/quantity/total.
  #
  # Assumption about CART-01's cart_items contract (see CHECKOUT-01 report):
  # `last_displayed_unit_amount_minor` / `currency` are the cart service's own
  # server-computed, catalog-derived price cache for that line, kept in sync by
  # CART-01 as prices are observed. NULL on both together (enforced by the
  # cart_items_amount_currency_pair_check constraint) is the catalog's explicit
  # "unknown price" state, and a cart holding one blocks checkout entirely.
  class LineItemPricer
    LineItem = Data.define(:product_variant_id, :name, :unit_amount_minor, :quantity, :currency)

    def call(cart)
      raise Error.new(:cart_empty) unless cart.respond_to?(:cart_items)

      items = cart.cart_items.to_a
      raise Error.new(:cart_empty) if items.empty?

      items.map { |item| build_line_item(item, cart) }.sort_by(&:product_variant_id).freeze
    end

    private
      def build_line_item(item, cart)
        raise Error.new(:unknown_price) if item.last_displayed_unit_amount_minor.nil? || item.currency.nil?

        amount = item.last_displayed_unit_amount_minor
        quantity = item.quantity
        currency = item.currency.to_s.strip.upcase

        raise Error.new(:invalid_input) unless amount.is_a?(Integer) && amount >= 0
        raise Error.new(:invalid_input) unless quantity.is_a?(Integer) && quantity >= 1
        raise Error.new(:currency_mismatch) if currency != cart.currency.to_s.strip.upcase

        LineItem.new(
          product_variant_id: item.product_variant_id,
          name: line_item_name(item),
          unit_amount_minor: amount,
          quantity: quantity,
          currency: currency
        ).freeze
      end

      def line_item_name(item)
        variant = item.respond_to?(:product_variant) ? item.product_variant : nil
        title = variant&.title
        title.presence || "Item #{item.product_variant_id}"
      end
  end
end
