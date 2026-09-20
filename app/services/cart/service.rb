require "digest"
require "json"

# Server-authoritative cart mutations (WP-11). Identity always comes from a
# trusted ShoppingSession the caller already resolved server-side -- never from
# an id supplied by the browser, a form field, or the voice model. Quantities
# and prices are validated/observed here; totals are derived in Cart::Snapshot
# from server-stored values only.
#
# Idempotency: every mutating call takes a client_mutation_id (UUID). A cart's
# mutation history is unique on (cart_id, client_mutation_id). A replayed
# request whose canonical fields hash the same as the stored mutation is a
# no-op that returns the current snapshot; a reused id with a different
# canonical request is rejected with :mutation_conflict. Each mutation is
# applied inside a single transaction that holds a row lock on the cart, so
# concurrent requests against the same cart are serialized and a duplicate
# add cannot create two cart_items rows or double count quantity.
class Cart::Service
  DEFAULT_CURRENCY = "USD"
  MUTATION_ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i

  def initialize(clock: -> { Time.current }, resolver: Cart::CatalogVariantResolver.new)
    @clock = clock
    @resolver = resolver
  end

  def find_or_create_active_cart(shopping_session:)
    validate_session!(shopping_session)

    ::Cart.find_by(shopping_session: shopping_session, status: "active") || create_active_cart!(shopping_session)
  end

  def snapshot(shopping_session:)
    cart = find_or_create_active_cart(shopping_session: shopping_session)
    Cart::Snapshot.build(cart)
  end

  # catalog_product_id / catalog_variant_id are the same supplier-facing
  # catalog ids already used by search_products/get_product_details and the
  # product pages -- never a local database id.
  def add_item(shopping_session:, catalog_product_id:, catalog_variant_id:, quantity:, client_mutation_id:)
    validate_quantity!(quantity)
    resolution = @resolver.call(catalog_product_id: catalog_product_id, catalog_variant_id: catalog_variant_id)

    mutate(
      shopping_session: shopping_session, client_mutation_id: client_mutation_id, operation: "add_item",
      product_variant: resolution.product_variant, quantity_delta: quantity,
      request_fields: { "op" => "add_item", "product_variant_id" => resolution.product_variant.id, "quantity" => quantity }
    ) do |cart|
      item = cart.cart_items.find_or_initialize_by(product_variant: resolution.product_variant)
      item.quantity = item.quantity.to_i + quantity
      item.added_at ||= @clock.call
      apply_price!(item, resolution.price)
      item.save!
    end
  end

  def change_quantity(shopping_session:, product_variant_id:, quantity:, client_mutation_id:)
    validate_quantity!(quantity)
    product_variant = find_product_variant!(product_variant_id)

    mutate(
      shopping_session: shopping_session, client_mutation_id: client_mutation_id, operation: "change_quantity",
      product_variant: product_variant, requested_quantity: quantity,
      request_fields: { "op" => "change_quantity", "product_variant_id" => product_variant.id, "quantity" => quantity }
    ) do |cart|
      item = cart.cart_items.find_by(product_variant: product_variant)
      raise Cart::Error.new(:not_found) unless item

      item.update!(quantity: quantity)
    end
  end

  def remove_item(shopping_session:, product_variant_id:, client_mutation_id:)
    product_variant = find_product_variant!(product_variant_id)

    mutate(
      shopping_session: shopping_session, client_mutation_id: client_mutation_id, operation: "remove_item",
      product_variant: product_variant,
      request_fields: { "op" => "remove_item", "product_variant_id" => product_variant.id }
    ) do |cart|
      cart.cart_items.find_by(product_variant: product_variant)&.destroy!
    end
  end

  private
    def create_active_cart!(shopping_session)
      now = @clock.call
      # A cart cannot outlive its shopping session, and last_activity_at can never be
      # after expires_at (carts_expiry_check). Clamp rather than let a session that is
      # right at its boundary raise a database constraint violation.
      activity = [ now, shopping_session.expires_at ].min
      ::Cart.create!(
        shopping_session: shopping_session, user: shopping_session.user, status: "active",
        currency: DEFAULT_CURRENCY, last_activity_at: activity, expires_at: shopping_session.expires_at
      )
    rescue ActiveRecord::RecordNotUnique
      ::Cart.find_by(shopping_session: shopping_session, status: "active") ||
        raise(Cart::Error.new(:conflict))
    end

    def find_product_variant!(product_variant_id)
      id = Integer(product_variant_id, exception: false)
      raise Cart::Error.new(:invalid_input) unless id

      ProductVariant.find_by(id: id) || raise(Cart::Error.new(:not_found))
    end

    def mutate(shopping_session:, client_mutation_id:, operation:, product_variant:, request_fields:,
        requested_quantity: nil, quantity_delta: nil)
      validate_session!(shopping_session)
      validate_mutation_id!(client_mutation_id)
      cart = find_or_create_active_cart(shopping_session: shopping_session)
      request_hash = canonical_hash(request_fields.merge("cart_id" => cart.id))

      cart.with_lock do
        apply_mutation!(cart, client_mutation_id, operation, product_variant, requested_quantity,
          quantity_delta, request_hash) { yield(cart) }
      end

      Cart::Snapshot.build(cart.reload)
    rescue ActiveRecord::RecordInvalid
      raise Cart::Error.new(:invalid_input)
    end

    def apply_mutation!(cart, client_mutation_id, operation, product_variant, requested_quantity,
        quantity_delta, request_hash)
      existing = cart.cart_mutations.find_by(client_mutation_id: client_mutation_id)
      if existing
        raise Cart::Error.new(:mutation_conflict) unless secure_equal?(existing.request_hash, request_hash)
        raise Cart::Error.new(existing.error_code.to_sym) if existing.status == "failed"
        return
      end

      now = @clock.call
      begin
        yield
        cart.cart_mutations.create!(
          client_mutation_id: client_mutation_id, operation: operation, product_variant: product_variant,
          requested_quantity: requested_quantity, quantity_delta: quantity_delta, request_hash: request_hash,
          status: "succeeded", started_at: now, completed_at: @clock.call
        )
        cart.update!(last_activity_at: [ @clock.call, cart.expires_at ].min)
      rescue Cart::Error => error
        cart.cart_mutations.create!(
          client_mutation_id: client_mutation_id, operation: operation, product_variant: product_variant,
          requested_quantity: requested_quantity, quantity_delta: quantity_delta, request_hash: request_hash,
          status: "failed", error_code: error.code.to_s, started_at: now, completed_at: @clock.call
        )
        raise
      end
    end

    def apply_price!(item, price)
      if price.state == :known
        item.last_displayed_unit_amount_minor = price.amount_minor
        item.currency = price.currency
      else
        item.last_displayed_unit_amount_minor = nil
        item.currency = nil
      end
    end

    def canonical_hash(fields)
      Digest::SHA256.digest(fields.sort.to_h.to_json)
    end

    def secure_equal?(left, right)
      return false unless left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize

      ActiveSupport::SecurityUtils.secure_compare(left, right)
    end

    def validate_session!(shopping_session)
      raise Cart::Error.new(:invalid_input) unless shopping_session.is_a?(ShoppingSession)
    end

    def validate_quantity!(quantity)
      raise Cart::Error.new(:quantity_invalid) unless quantity.is_a?(Integer) && quantity > 0
    end

    def validate_mutation_id!(client_mutation_id)
      return if client_mutation_id.is_a?(String) && client_mutation_id.match?(MUTATION_ID_PATTERN)

      raise Cart::Error.new(:invalid_input)
    end
end
