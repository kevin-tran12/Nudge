require "application_system_test_case"

class HomePageTest < ApplicationSystemTestCase
  VIEWPORTS = {
    "compact phone" => [ 320, 720 ],
    "phone" => [ 375, 812 ],
    "tablet" => [ 768, 1024 ],
    "desktop" => [ 1280, 900 ]
  }.freeze

  test "the home page is a responsive working shopping surface at every supported viewport" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)
      visit root_path

      assert_equal width, page.evaluate_script("window.innerWidth"), "#{name} viewport width"
      assert_selector "h1", count: 1
      assert_selector "input#q"
      assert_selector "[data-voice-launcher][data-voice-state='idle']"
      assert_selector "article", minimum: 1
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)
    end
  end

  test "search from the home page reuses the catalog search page" do
    set_viewport(1280, 900)
    visit root_path

    fill_in "Search products", with: "storage bin"
    find_field("Search products").native.send_keys(:enter)

    assert_selector "h1", text: "Browse the sample catalog"
    assert_selector "a[href='#{product_path('00001234')}']", text: "Stacking storage bin"
  end

  test "the voice disclosure modal opens and closes correctly from the home page" do
    visit root_path

    click_button "Start voice shopping"
    assert_selector "[data-voice-launcher][data-voice-state='disclosure_required']"
    assert page.evaluate_script("document.querySelector('[data-voice-disclosure]').open")
    assert page.evaluate_script(<<~JAVASCRIPT), "focus should move into the open dialog"
      document.querySelector('[data-voice-disclosure]').contains(document.activeElement)
    JAVASCRIPT

    click_button "Not now"
    assert_selector "[data-voice-launcher][data-voice-state='idle']"
    refute page.evaluate_script("document.querySelector('[data-voice-disclosure]').open")
    assert page.evaluate_script(<<~JAVASCRIPT), "focus should return to the trigger button"
      document.activeElement === document.querySelector('[data-voice-action="start"]')
    JAVASCRIPT
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
