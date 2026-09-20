require "test_helper"

class CartItemsControllerTest < ActionDispatch::IntegrationTest
  include TestSupport::IdentityRecords
  include TestSupport::CatalogRecords

  setup do
    travel_to TestSupport::IdentityRecords::REFERENCE_TIME
    clear_identity_records
    clear_catalog_records
    create_cj_supplier
  end

  teardown do
    clear_catalog_records
    clear_identity_records
    travel_back
  end

  test "adding an item without any existing session bootstraps one and redirects to the cart" do
    post cart_items_path, params: {
      catalog_product_id: "00001234", catalog_variant_id: "00005678", quantity: 2,
      client_mutation_id: SecureRandom.uuid
    }

    assert_redirected_to cart_path
    assert_equal 1, ShoppingSession.count
    assert_equal 2, CartItem.sole.quantity
  end

  test "a double submit with the same client_mutation_id does not double the quantity" do
    session = create_shopping_session
    set_session_cookie(session)
    mutation_id = SecureRandom.uuid

    2.times do
      post cart_items_path, params: {
        catalog_product_id: "00001234", catalog_variant_id: "00005678", quantity: 1, client_mutation_id: mutation_id
      }
    end

    assert_equal 1, CartItem.count
    assert_equal 1, CartItem.sole.quantity
  end

  test "a forged price/total parameter never influences the stored price" do
    session = create_shopping_session
    set_session_cookie(session)

    post cart_items_path, params: {
      catalog_product_id: "00001234", catalog_variant_id: "00005678", quantity: 1,
      client_mutation_id: SecureRandom.uuid, unit_amount_minor: 1, total: 1, price: 1
    }

    assert_equal 1234, CartItem.sole.last_displayed_unit_amount_minor
  end

  test "updating quantity for another session's item is rejected" do
    session_a = create_shopping_session
    session_b = create_shopping_session

    set_session_cookie(session_a)
    post cart_items_path, params: {
      catalog_product_id: "00001234", catalog_variant_id: "00005678", quantity: 1, client_mutation_id: SecureRandom.uuid
    }
    item = CartItem.sole

    set_session_cookie(session_b)
    patch cart_item_path(item), params: { quantity: 9, client_mutation_id: SecureRandom.uuid }

    assert_redirected_to cart_path
    assert_equal "That item is no longer in your cart.", flash[:alert]
    assert_equal 1, item.reload.quantity
  end

  test "quantity zero is rejected with a redirect and the item is unchanged" do
    session = create_shopping_session
    set_session_cookie(session)
    post cart_items_path, params: {
      catalog_product_id: "00001234", catalog_variant_id: "00005678", quantity: 1, client_mutation_id: SecureRandom.uuid
    }
    item = CartItem.sole

    patch cart_item_path(item), params: { quantity: 0, client_mutation_id: SecureRandom.uuid }

    assert_redirected_to cart_path
    assert_equal 1, item.reload.quantity
  end

  test "removing an item deletes it" do
    session = create_shopping_session
    set_session_cookie(session)
    post cart_items_path, params: {
      catalog_product_id: "00001234", catalog_variant_id: "00005678", quantity: 1, client_mutation_id: SecureRandom.uuid
    }
    item = CartItem.sole

    delete cart_item_path(item), params: { client_mutation_id: SecureRandom.uuid }

    assert_redirected_to cart_path
    assert_equal 0, CartItem.count
  end

  private
    def set_session_cookie(session)
      jar = ActionDispatch::Cookies::CookieJar.build(ActionDispatch::TestRequest.create, {})
      Identity::BrowserSessionCookie.new(
        cookie_jar: jar, clock: -> { TestSupport::IdentityRecords::REFERENCE_TIME },
        secure: false, environment: "test"
      ).write(shopping_session: session)
      cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = jar[Identity::BrowserSessionCookie::COOKIE_NAME]
    end
end
