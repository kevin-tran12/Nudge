# TEMPORARY test-only stand-ins for CART-01's Cart/CartItem models.
#
# CHECKOUT-01 is built against `Cart`/`CartItem` per its brief ("assume Cart,
# CartItem, and a cart service exist and build against them"), but CART-01 has
# not merged into this worktree yet, so those constants do not exist. These
# minimal ActiveRecord classes are backed by the real `carts`/`cart_items`
# tables (already created by DB-07) purely so CHECKOUT-01's own tests can
# exercise real DB behavior (uniqueness, session isolation, lock_version).
#
# `unless defined?` means this file becomes an inert no-op the moment
# CART-01's real app/models/cart.rb and app/models/cart_item.rb land -- delete
# this file at that point rather than relying on the guard indefinitely.
#
# Assumed CART-01 interface (documented in the CHECKOUT-01 report):
#   Cart#status == "active" marks the one cart Checkout may act on for a
#     shopping session (enforced today by a partial unique index).
#   Cart#currency is the cart's ISO-4217 currency for every line item.
#   Cart has_many :cart_items.
#   CartItem#quantity, #product_variant_id are authoritative.
#   CartItem#last_displayed_unit_amount_minor / #currency are the cart
#     service's own server-computed, catalog-derived price cache for that
#     item -- NULL/NULL together means "unknown price" (see the
#     cart_items_amount_currency_pair_check constraint). CHECKOUT-01 treats
#     this pair, not a fresh independent repricing pass, as "catalog data"
#     for recomputing totals; see the report for why.
unless defined?(Cart)
  class Cart < ApplicationRecord
    self.table_name = "carts"
    has_many :cart_items, inverse_of: :cart, dependent: :destroy
  end
end

unless defined?(CartItem)
  class CartItem < ApplicationRecord
    self.table_name = "cart_items"
    belongs_to :cart, inverse_of: :cart_items
    belongs_to :product_variant
  end
end
