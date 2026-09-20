require "test_helper"

class CheckoutControllerTest < ActionDispatch::IntegrationTest
  include TestSupport::IdentityRecords
  include TestSupport::CheckoutRecords

  setup do
    travel_to TestSupport::CheckoutRecords::REFERENCE_TIME
    clear_checkout_records
    clear_identity_records
  end

  teardown do
    clear_checkout_records
    clear_identity_records
    travel_back
  end

  test "GET /checkout without a shopping session shows an empty cart, never a price" do
    get new_checkout_path

    assert_response :success
    assert_select "h2", "Your cart is empty"
  end

  test "GET /checkout shows the server-recomputed cart total" do
    session = create_shopping_session
    cart = create_cart(shopping_session: session)
    add_cart_item(cart: cart, quantity: 2, unit_amount_minor: 500, currency: "USD")
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)

    get new_checkout_path

    assert_response :success
    assert_select "*", text: /USD 10\.00/
  end

  test "POST /checkout with an empty cart refuses checkout" do
    session = create_shopping_session
    create_cart(shopping_session: session)
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)

    post checkout_path

    assert_response :unprocessable_entity
    assert_select "h1", "Your cart is empty"
  end

  test "POST /checkout with an unknown-price item refuses checkout" do
    session = create_shopping_session
    cart = create_cart(shopping_session: session)
    add_cart_item(cart: cart, quantity: 1, unit_amount_minor: nil, currency: nil)
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)

    post checkout_path

    assert_response :unprocessable_entity
    assert_select "h1", "Price not confirmed yet"
  end

  test "POST /checkout redirects to the Stripe (fixture) hosted checkout page" do
    session = create_shopping_session
    cart = create_cart(shopping_session: session)
    add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)

    assert_difference -> { CheckoutIntent.count }, 1 do
      post checkout_path
    end

    assert_response :redirect
    assert_match %r{\Ahttps://checkout\.stripe\.test/fixture/}, response.location
  end

  test "a duplicate POST /checkout does not open a second Stripe session" do
    session = create_shopping_session
    cart = create_cart(shopping_session: session)
    add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)

    post checkout_path
    first_location = response.location

    assert_no_difference -> { CheckoutIntent.count } do
      post checkout_path
    end
    assert_equal first_location, response.location
  end

  test "GET the confirmation page for an unpaid session does not render as confirmed" do
    session = create_shopping_session
    cart = create_cart(shopping_session: session)
    add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)
    post checkout_path
    public_id = CheckoutIntent.last.public_id

    get checkout_confirmation_path(public_id)

    assert_response :success
    assert_select "[data-checkout-confirmed='false']"
    assert_select "[data-checkout-confirmed='true']", count: 0
  end

  test "a forged confirmation id renders not found, not a confirmed purchase" do
    session = create_shopping_session
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)

    get checkout_confirmation_path("00000000-0000-4000-8000-000000000000")

    assert_response :not_found
    assert_select "[data-checkout-confirmed='true']", count: 0
  end

  test "another shopper's session id does not render someone else's confirmation" do
    owner = create_shopping_session
    owner_cart = create_cart(shopping_session: owner)
    add_cart_item(cart: owner_cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(owner)
    post checkout_path
    public_id = CheckoutIntent.last.public_id
    delete_all_cookies

    intruder = create_shopping_session
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(intruder)

    get checkout_confirmation_path(public_id)

    assert_response :not_found
    assert_select "[data-checkout-confirmed='true']", count: 0
  end

  test "a genuinely paid Stripe session renders confirmed and converts the intent" do
    session = create_shopping_session
    cart = create_cart(shopping_session: session)
    add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)
    post checkout_path
    public_id = CheckoutIntent.last.public_id

    stub_paid_stripe_session do
      get checkout_confirmation_path(public_id)
    end

    assert_response :success
    assert_select "[data-checkout-confirmed='true']"
    assert_equal "converted", CheckoutIntent.find_by!(public_id: public_id).status
  end

  private
    def signed_cookie_for(session)
      request = ActionDispatch::TestRequest.create
      jar = ActionDispatch::Cookies::CookieJar.build(request, {})
      Identity::BrowserSessionCookie.new(
        cookie_jar: jar,
        clock: -> { TestSupport::CheckoutRecords::REFERENCE_TIME },
        secure: false,
        environment: "test"
      ).write(shopping_session: session)
      jar[Identity::BrowserSessionCookie::COOKIE_NAME]
    end

    def delete_all_cookies
      cookies.delete(Identity::BrowserSessionCookie::COOKIE_NAME)
    end

    def stub_paid_stripe_session
      original = Integrations::Stripe::Adapter.instance_method(:retrieve_checkout_session)
      Integrations::Stripe::Adapter.define_method(:retrieve_checkout_session) do |id|
        Integrations::Stripe::Adapter::Result.new(
          id: id, url: nil, status: "complete", currency: "usd", amount_total: nil, payment_status: "paid"
        )
      end
      yield
    ensure
      Integrations::Stripe::Adapter.define_method(:retrieve_checkout_session, original)
    end
end
