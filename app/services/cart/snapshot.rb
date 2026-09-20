# Read-only, server-computed projection of a cart used by the cart page, the
# add-to-cart response, and the voice tool. Never trusts a stored/displayed
# price as a substitute for the unknown state: an item with an unknown price
# forces the whole total to :unknown rather than silently treating it as zero.
class Cart::Snapshot
  LineItem = Data.define(
    :cart_item_id, :product_variant_id, :title, :quantity,
    :unit_amount_minor, :currency, :line_total_minor, :price_known
  )
  Total = Data.define(:state, :amount_minor, :currency)
  Result = Data.define(:cart, :line_items, :total, :currency)

  def self.build(cart)
    items = cart.cart_items.includes(product_variant: :product).order(:id).map { |item| line_item(item) }
    Result.new(cart: cart, line_items: items, total: total_for(items, cart.currency), currency: cart.currency).freeze
  end

  def self.line_item(item)
    variant = item.product_variant
    title = variant&.title.presence || variant&.product&.title.presence || "Item"
    LineItem.new(
      cart_item_id: item.id, product_variant_id: item.product_variant_id, title: title,
      quantity: item.quantity, unit_amount_minor: item.last_displayed_unit_amount_minor,
      currency: item.currency, line_total_minor: item.line_total_minor, price_known: item.known_price?
    )
  end
  private_class_method :line_item

  def self.total_for(items, currency)
    return Total.new(state: :known, amount_minor: 0, currency: currency) if items.empty?
    return Total.new(state: :unknown, amount_minor: nil, currency: currency) if items.any? { |item| !item.price_known }

    Total.new(state: :known, amount_minor: items.sum(&:line_total_minor), currency: currency)
  end
  private_class_method :total_for
end
