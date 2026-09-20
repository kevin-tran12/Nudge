module TestSupport
  module CheckoutRecords
    # Duplicated from TestSupport::IdentityRecords::REFERENCE_TIME rather than
    # referenced: test/support files load in alphabetical order and
    # checkout_records.rb loads before identity_records.rb.
    REFERENCE_TIME = Time.utc(2026, 9, 20, 12, 0, 0)

    def clear_checkout_records
      CheckoutIntent.delete_all
      CartItem.delete_all if defined?(CartItem)
      Cart.delete_all if defined?(Cart)
      ProductVariant.delete_all
      Product.delete_all
    end

    def create_product(title: "Sample product")
      Product.create!(status: "active", title: title, description: "")
    end

    def create_product_variant(product: nil, title: "Sample variant")
      product ||= create_product
      ProductVariant.create!(product: product, title: title, option_schema_version: 1)
    end

    def create_cart(shopping_session:, status: "active", currency: "USD",
      last_activity_at: REFERENCE_TIME - 1.minute, expires_at: REFERENCE_TIME + 1.hour)
      Cart.create!(
        shopping_session_id: shopping_session.id, status: status, currency: currency,
        last_activity_at: last_activity_at, expires_at: expires_at
      )
    end

    def add_cart_item(cart:, product_variant: nil, quantity: 1, unit_amount_minor: 1_234, currency: cart.currency)
      product_variant ||= create_product_variant
      CartItem.create!(
        cart: cart, product_variant: product_variant, quantity: quantity,
        last_displayed_unit_amount_minor: unit_amount_minor, currency: currency,
        added_at: REFERENCE_TIME - 1.minute
      )
    end
  end
end
