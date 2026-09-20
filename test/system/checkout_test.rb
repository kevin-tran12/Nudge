require "application_system_test_case"

# Covers the two pages CHECKOUT-01 owns across the four required widths.
# Deliberately does not attempt to drive an authenticated shopping session
# with a populated cart through the browser: this worktree's identity cookie
# is HMAC-signed with Rails.application.key_generator inside the app process,
# and there is no real page-driven flow (no cart UI yet -- CART-01) that
# would let the browser itself acquire a session cookie for a specific
# fixture cart. Server-side coverage for cart totals, pricing, idempotency,
# and confirmation status already lives in test/services/checkout and
# test/controllers/checkout_controller_test.rb; this file only verifies the
# responsive/accessible shell of both pages in the states a browser can
# reach on its own: anonymous/empty and not-found.
class CheckoutTest < ApplicationSystemTestCase
  VIEWPORTS = {
    "compact phone" => [ 320, 720 ],
    "phone" => [ 375, 812 ],
    "tablet" => [ 768, 1024 ],
    "desktop" => [ 1280, 900 ]
  }.freeze

  test "the checkout entry page is responsive and accessible with no cart" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)
      visit new_checkout_path

      assert_selector "h1", text: "Review your order"
      assert_selector "h2", text: "Your cart is empty"
      assert_no_selector "[data-checkout-confirmed]"
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)
    end
  end

  test "the confirmation page for an unknown checkout id is responsive and never fabricates success" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)
      visit checkout_confirmation_path("00000000-0000-4000-8000-000000000000")

      assert_selector "h1", text: "Checkout unavailable"
      assert_no_selector "[data-checkout-confirmed='true']"
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)
    end
  end

  private
    def set_viewport(width, height)
      page.current_window.resize_to(width, height)
      actual_width = page.evaluate_script("window.innerWidth")
      actual_height = page.evaluate_script("window.innerHeight")
      page.current_window.resize_to(width + (width - actual_width), height + (height - actual_height))
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
