require "test_helper"

class CartsControllerTest < ActionDispatch::IntegrationTest
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

  test "shows an empty cart for a first-time visitor and bootstraps a session" do
    get cart_path

    assert_response :success
    assert_select "h2", text: "Your cart is empty"
    assert_equal 1, ShoppingSession.count
  end

  test "shows line items and a known total after adding an item" do
    session = create_shopping_session
    set_session_cookie(session)
    post cart_items_path, params: {
      catalog_product_id: "00001234", catalog_variant_id: "00005678", quantity: 2, client_mutation_id: SecureRandom.uuid
    }

    get cart_path

    assert_response :success
    assert_select "[data-cart-total-state=known]"
    assert_match "USD 24.68", response.body
  end

  test "shows the total as unavailable when an item price is unknown" do
    session = create_shopping_session
    set_session_cookie(session)
    post cart_items_path, params: {
      catalog_product_id: "00001234", catalog_variant_id: "fixture-variant-unknown", quantity: 1,
      client_mutation_id: SecureRandom.uuid
    }

    get cart_path

    assert_response :success
    assert_select "[data-cart-total-state=unknown]"
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
