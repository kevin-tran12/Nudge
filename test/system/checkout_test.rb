require "application_system_test_case"

class CheckoutTest < ApplicationSystemTestCase
  include TestSupport::IdentityRecords
  include TestSupport::CheckoutRecords

  VIEWPORTS = {
    "compact phone" => [ 320, 720 ],
    "phone" => [ 375, 812 ],
    "tablet" => [ 768, 1024 ],
    "desktop" => [ 1280, 900 ]
  }.freeze

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

  test "the checkout entry page is responsive, shows a server-recomputed total, and never fabricates a confirmation" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)

      # A forged/unknown confirmation id never renders as a successful purchase.
      visit checkout_confirmation_path("00000000-0000-4000-8000-000000000000")
      assert_no_horizontal_overflow(name)
      assert_no_selector "[data-checkout-confirmed='true']"

      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 2, unit_amount_minor: 799, currency: "USD")
      set_session_cookie(session)

      visit new_checkout_path
      assert_selector "h1", text: "Review your order"
      assert_text "USD 15.98"
      assert_selector "button", text: "Checkout with Stripe (test)"
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)

      clear_checkout_records
      clear_identity_records
    end
  end

  test "the confirmation page for an unpaid checkout is responsive and never claims success" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)

      session = create_shopping_session
      cart = create_cart(shopping_session: session)
      add_cart_item(cart: cart, quantity: 1, unit_amount_minor: 500, currency: "USD")
      set_session_cookie(session)

      intent_public_id = Checkout::BeginCheckout.new(
        success_url: ->(public_id) { "https://example.test/checkout/#{public_id}" },
        cancel_url: -> { "https://example.test/products" }
      ).call(shopping_session: session).intent_public_id

      visit checkout_confirmation_path(intent_public_id)
      assert_selector "h1", text: "Payment not yet confirmed"
      assert_selector "[data-checkout-confirmed='false']"
      assert_no_selector "[data-checkout-confirmed='true']"
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)

      clear_checkout_records
      clear_identity_records
    end
  end

  private
    def set_viewport(width, height)
      page.current_window.resize_to(width, height)
      actual_width = page.evaluate_script("window.innerWidth")
      actual_height = page.evaluate_script("window.innerHeight")
      page.current_window.resize_to(width + (width - actual_width), height + (height - actual_height))
    end

    def set_session_cookie(session)
      visit "/"
      request = ActionDispatch::TestRequest.create
      jar = ActionDispatch::Cookies::CookieJar.build(request, {})
      Identity::BrowserSessionCookie.new(
        cookie_jar: jar, clock: -> { TestSupport::CheckoutRecords::REFERENCE_TIME }, secure: false, environment: "test"
      ).write(shopping_session: session)
      raw = jar[Identity::BrowserSessionCookie::COOKIE_NAME]
      page.driver.browser.manage.add_cookie(name: Identity::BrowserSessionCookie::COOKIE_NAME.to_s, value: raw, path: "/")
    end

    def assert_no_horizontal_overflow(viewport)
      dimensions = page.evaluate_script(<<~JAVASCRIPT)
        ({ clientWidth: document.documentElement.clientWidth, scrollWidth: document.documentElement.scrollWidth })
      JAVASCRIPT
      assert_operator dimensions.fetch("scrollWidth"), :<=, dimensions.fetch("clientWidth"),
        "#{viewport} has horizontal overflow"
    end

    def assert_minimum_target_sizes(viewport)
      targets = page.evaluate_script(<<~JAVASCRIPT)
        Array.from(document.querySelectorAll("a[href], button, input, select, textarea, summary, [tabindex]:not([tabindex='-1'])"))
          .filter((element) => !element.disabled && getComputedStyle(element).visibility !== "hidden")
          .map((element) => {
            const rect = element.getBoundingClientRect();
            return { name: element.textContent.trim() || element.getAttribute("aria-label"), width: rect.width, height: rect.height };
          });
      JAVASCRIPT
      targets.each do |target|
        assert_operator target.fetch("width"), :>=, 44, "#{viewport}: #{target.fetch('name')} width"
        assert_operator target.fetch("height"), :>=, 44, "#{viewport}: #{target.fetch('name')} height"
      end
    end
end
