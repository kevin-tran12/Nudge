require "application_system_test_case"

class CartTest < ApplicationSystemTestCase
  VIEWPORTS = {
    "compact phone" => [ 320, 720 ],
    "phone" => [ 375, 812 ],
    "tablet" => [ 768, 1024 ],
    "desktop" => [ 1280, 900 ]
  }.freeze

  test "adding a sample item and managing it from the cart page is keyboard operable and responsive" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)
      visit product_path("00001234")

      click_button "Add to cart", match: :first
      assert_current_path cart_path
      assert_selector "h1", text: "Your cart"
      assert_text "Small bin"
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)

      within "li", text: "Small bin" do
        fill_in "Quantity for Small bin", with: "3"
        click_button "Update"
      end
      assert_text "3", minimum: 1

      within "li", text: "Small bin" do
        click_button "Remove"
      end
      assert_selector "h2", text: "Your cart is empty"
      assert_no_horizontal_overflow(name)
    end
  end

  test "the cart page is reachable and operable with only the keyboard" do
    set_viewport(320, 720)
    visit product_path("00001234")
    click_button "Add to cart", match: :first
    visit cart_path

    send_key(:tab)
    focused = page.evaluate_script("document.activeElement.textContent.trim() || document.activeElement.tagName")
    assert focused.present?
    assert_visible_focus
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
        Array.from(document.querySelectorAll("a[href], button, input:not([type='hidden']), select, textarea, summary, [tabindex]:not([tabindex='-1'])"))
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

    def send_key(key)
      page.driver.browser.action.send_keys(key).perform
    end

    def assert_visible_focus
      focus = page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const style = getComputedStyle(document.activeElement);
          return { outline: style.outlineStyle, shadow: style.boxShadow };
        })()
      JAVASCRIPT
      assert focus.fetch("outline") != "none" || focus.fetch("shadow") != "none"
    end
end
