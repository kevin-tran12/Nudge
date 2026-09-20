# Owned by CHECKOUT-01. Table provided by DB-07 (db/migrate/20260920000007).
#
# `cart_id` intentionally has no `belongs_to`/association helper here: the
# Cart model belongs to the CART-01 package and does not exist in this
# worktree. Callers load the cart with `Cart.find(intent.cart_id)` (or the
# equivalent CART-01 finder) instead.
class CheckoutIntent < ApplicationRecord
  EXECUTION_MODES = %w[fixture sandbox live].freeze
  STATUSES = %w[open blocked converted expired cancelled].freeze
  PROVIDER = "stripe"

  validates :execution_mode, inclusion: { in: EXECUTION_MODES }
  validates :status, inclusion: { in: STATUSES }
  validates :provider, presence: true
  validates :intent_key, presence: true
end
