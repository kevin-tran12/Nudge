class CartItem < ApplicationRecord
  belongs_to :cart, inverse_of: :cart_items
  belongs_to :product_variant
  belongs_to :price_observation, optional: true

  validates :quantity, numericality: { only_integer: true, greater_than: 0 }
  validates :product_variant_id, uniqueness: { scope: :cart_id }

  # Server-observed price at the moment this item was added or last refreshed.
  # nil means the price was unknown at observation time and must never be
  # treated as zero when computing a cart total.
  def known_price?
    last_displayed_unit_amount_minor.present? && currency.present?
  end

  def line_total_minor
    return nil unless known_price?

    last_displayed_unit_amount_minor * quantity
  end
end
