require "test_helper"

class Cart::ServiceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  include TestSupport::IdentityRecords
  include TestSupport::CatalogRecords

  PRODUCT_ID = "00001234"
  KNOWN_VARIANT_ID = "00005678"
  UNKNOWN_PRICE_VARIANT_ID = "fixture-variant-unknown"

  setup do
    travel_to TestSupport::IdentityRecords::REFERENCE_TIME
    clear_identity_records
    clear_catalog_records
    create_cj_supplier
    @service = Cart::Service.new
  end

  teardown do
    clear_catalog_records
    clear_identity_records
    travel_back
  end

  test "add_item creates the session's cart and a line item priced from server-observed catalog data" do
    session = create_shopping_session
    snapshot = add(session, KNOWN_VARIANT_ID, 2)

    assert_equal 1, snapshot.line_items.length
    line = snapshot.line_items.first
    assert_equal 2, line.quantity
    assert_equal 1234, line.unit_amount_minor
    assert_equal "USD", line.currency
    assert_equal 2468, line.line_total_minor
    assert_equal :known, snapshot.total.state
    assert_equal 2468, snapshot.total.amount_minor
  end

  test "adding the same variant again increments quantity on the same line item, not a second row" do
    session = create_shopping_session
    add(session, KNOWN_VARIANT_ID, 1)
    snapshot = add(session, KNOWN_VARIANT_ID, 3, mutation_id: SecureRandom.uuid)

    assert_equal 1, snapshot.line_items.length
    assert_equal 4, snapshot.line_items.first.quantity
    assert_equal 1, CartItem.count
  end

  test "an item with an unknown price never contributes zero and forces the total unknown" do
    session = create_shopping_session
    add(session, KNOWN_VARIANT_ID, 1)
    snapshot = add(session, UNKNOWN_PRICE_VARIANT_ID, 1, mutation_id: SecureRandom.uuid)

    unknown_line = snapshot.line_items.find { |item| !item.price_known }
    assert unknown_line
    assert_nil unknown_line.unit_amount_minor
    assert_nil unknown_line.line_total_minor
    assert_equal :unknown, snapshot.total.state
    assert_nil snapshot.total.amount_minor
  end

  test "quantity must be a positive integer" do
    session = create_shopping_session

    assert_cart_error(:quantity_invalid) { add(session, KNOWN_VARIANT_ID, 0) }
    assert_cart_error(:quantity_invalid) { add(session, KNOWN_VARIANT_ID, -1) }
  end

  test "change_quantity sets an absolute quantity and remove_item deletes the line" do
    session = create_shopping_session
    add(session, KNOWN_VARIANT_ID, 1)
    product_variant_id = CartItem.last.product_variant_id

    snapshot = @service.change_quantity(shopping_session: session, product_variant_id: product_variant_id,
      quantity: 5, client_mutation_id: SecureRandom.uuid)
    assert_equal 5, snapshot.line_items.first.quantity

    snapshot = @service.remove_item(shopping_session: session, product_variant_id: product_variant_id,
      client_mutation_id: SecureRandom.uuid)
    assert_empty snapshot.line_items
    assert_equal 0, CartItem.count
  end

  test "change_quantity rejects zero and negative quantities" do
    session = create_shopping_session
    add(session, KNOWN_VARIANT_ID, 1)
    product_variant_id = CartItem.last.product_variant_id

    assert_cart_error(:quantity_invalid) do
      @service.change_quantity(shopping_session: session, product_variant_id: product_variant_id,
        quantity: 0, client_mutation_id: SecureRandom.uuid)
    end
  end

  test "a duplicate mutation id with an identical request is a no-op" do
    session = create_shopping_session
    mutation_id = SecureRandom.uuid
    add(session, KNOWN_VARIANT_ID, 2, mutation_id: mutation_id)
    snapshot = add(session, KNOWN_VARIANT_ID, 2, mutation_id: mutation_id)

    assert_equal 2, snapshot.line_items.first.quantity
    assert_equal 1, CartMutation.count
  end

  test "a reused mutation id with a different request is rejected" do
    session = create_shopping_session
    mutation_id = SecureRandom.uuid
    add(session, KNOWN_VARIANT_ID, 2, mutation_id: mutation_id)

    assert_cart_error(:mutation_conflict) { add(session, KNOWN_VARIANT_ID, 3, mutation_id: mutation_id) }
    assert_equal 2, CartItem.last.quantity
  end

  test "one shopping session always resolves to the same active cart" do
    session = create_shopping_session

    first = @service.find_or_create_active_cart(shopping_session: session)
    second = @service.find_or_create_active_cart(shopping_session: session)

    assert_equal first.id, second.id
    assert_equal 1, Cart.where(shopping_session: session).count
  end

  test "one shopping session resolves to a single active cart under genuine concurrent creation" do
    session = create_shopping_session
    session_id = session.id

    results = Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          local_session = ShoppingSession.find(session_id)
          Cart::Service.new.find_or_create_active_cart(shopping_session: local_session).id
        end
      end
    end.map(&:value)

    assert_equal 1, results.uniq.length
    assert_equal 1, Cart.where(shopping_session_id: session_id).count
  end

  test "a concurrent double add-to-cart results in one line item at the correct quantity" do
    session = create_shopping_session
    session_id = session.id
    @service.find_or_create_active_cart(shopping_session: session)

    Array.new(4) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          local_session = ShoppingSession.find(session_id)
          Cart::Service.new.add_item(shopping_session: local_session, catalog_product_id: PRODUCT_ID,
            catalog_variant_id: KNOWN_VARIANT_ID, quantity: 1, client_mutation_id: SecureRandom.uuid)
        end
      end
    end.each(&:join)

    assert_equal 1, CartItem.count
    assert_equal 4, CartItem.last.quantity
  end

  test "one session cannot read or mutate another session's cart" do
    session_a = create_shopping_session
    session_b = create_shopping_session
    add(session_a, KNOWN_VARIANT_ID, 1)
    product_variant_id = CartItem.last.product_variant_id

    assert_cart_error(:not_found) do
      @service.change_quantity(shopping_session: session_b, product_variant_id: product_variant_id,
        quantity: 3, client_mutation_id: SecureRandom.uuid)
    end

    snapshot_b = @service.snapshot(shopping_session: session_b)
    assert_empty snapshot_b.line_items
    assert_equal 1, @service.snapshot(shopping_session: session_a).line_items.first.quantity
  end

  test "an unknown catalog variant is rejected" do
    session = create_shopping_session

    assert_cart_error(:not_found) { add(session, "does-not-exist", 1) }
  end

  private
    def add(session, variant_id, quantity, mutation_id: SecureRandom.uuid)
      @service.add_item(shopping_session: session, catalog_product_id: PRODUCT_ID, catalog_variant_id: variant_id,
        quantity: quantity, client_mutation_id: mutation_id)
    end

    def assert_cart_error(code)
      error = assert_raises(Cart::Error) { yield }
      assert_equal code, error.code
    end
end
