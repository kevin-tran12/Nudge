require "application_system_test_case"

class CatalogBrowsingTest < ApplicationSystemTestCase
  VIEWPORTS = {
    "compact phone" => [ 320, 720 ],
    "phone" => [ 375, 812 ],
    "tablet" => [ 768, 1024 ],
    "desktop" => [ 1280, 900 ]
  }.freeze

  test "catalog index and detail are responsive accessible and make no supplier media requests" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)
      visit products_path

      assert_equal width, page.evaluate_script("window.innerWidth"), "#{name} viewport width"
      assert_shell(name, "Browse the sample catalog")
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)
      assert_selector "nav a[aria-current='page']", text: "Catalog"
      assert_no_supplier_media(name)

      click_link "Stacking storage bin"
      assert_shell(name, "Stacking storage bin")
      assert_text "Illustrative price: USD 12.34"
      assert_text "Illustrative price unavailable"
      assert_text "Availability unknown"
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)
      assert_no_supplier_media(name)
    end
  end

  { "short" => "I", "maximum unbroken" => "W" * 200 }.each do |label, title|
    test "rendered #{label} card title fits a compact phone with a full touch target" do
      set_viewport(320, 720)
      visit products_path
      product = Catalog::FixtureProductReader.new.detail(id: "00001234").with(title: title.freeze)
      card = ApplicationController.render(partial: "shared/catalog/product_card", locals: { product: })

      # Render the real partial with boundary data into the served page's real CSS/layout.
      page.execute_script("document.querySelector('main article').outerHTML = arguments[0]", card)

      assert_selector "article h2 a", exact_text: title
      assert_no_horizontal_overflow(label)
      assert_minimum_target_sizes(label)
      bounds = page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const link = document.querySelector('main article h2 a');
          const card = link.closest('article').getBoundingClientRect();
          const range = document.createRange();
          range.selectNodeContents(link);
          return {
            left: card.left, right: card.right,
            rows: Array.from(range.getClientRects()).map(rect => ({ left: rect.left, right: rect.right }))
          };
        })()
      JAVASCRIPT
      assert_operator bounds.fetch("rows").length, :>, 1 if title.bytesize == 200
      bounds.fetch("rows").each do |row|
        assert_operator row.fetch("left"), :>=, bounds.fetch("left") - 1
        assert_operator row.fetch("right"), :<=, bounds.fetch("right") + 1
      end
    end
  end

  test "empty and not found states remain navigable" do
    visit products_path(cursor: "1")
    assert_selector "h1", text: "Browse the sample catalog"
    assert_selector "h2", text: "No sample products on this page"

    visit product_path("unknown-product")
    assert_selector "h1", text: "Sample product not found"
    assert_link "Back to catalog", href: products_path
  end

  test "keyboard focus skip link aria current and reduced motion remain explicit" do
    set_viewport(320, 720)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia",
      features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    visit products_path

    assert page.evaluate_script("window.matchMedia('(prefers-reduced-motion: reduce)').matches")
    assert_equal "auto", page.evaluate_script("getComputedStyle(document.documentElement).scrollBehavior")
    send_key(:tab)
    assert_equal "Skip to content", page.evaluate_script("document.activeElement.textContent.trim()")
    assert_visible_focus
    send_key(:enter)
    assert_equal "main-content", page.evaluate_script("document.activeElement.id")
    assert_selector "nav a[aria-current='page']", count: 1, text: "Catalog"
    assert_selector "nav a[aria-current='page']", text: "Home", count: 0
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: []) if page.driver.browser
  end

  private
    def set_viewport(width, height)
      page.current_window.resize_to(width, height)
      actual_width = page.evaluate_script("window.innerWidth")
      actual_height = page.evaluate_script("window.innerHeight")
      page.current_window.resize_to(width + (width - actual_width), height + (height - actual_height))
    end

    def assert_shell(viewport, heading)
      assert_selector "header", count: 1
      assert_selector "nav[aria-label='Primary navigation']", count: 1
      assert_selector "main#main-content", count: 1
      assert_selector "footer", count: 1
      assert_selector "h1", count: 1, text: heading
      assert_equal "h1", page.first("main h1, main h2, main h3").tag_name
    rescue Minitest::Assertion => error
      raise Minitest::Assertion, "#{viewport}: #{error.message}"
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

    def assert_no_supplier_media(viewport)
      violations = page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const markup = Array.from(document.querySelectorAll("[src], [srcset], [style], link[href]"))
            .map((node) => node.outerHTML)
            .filter((html) => /cjdropshipping|aliyuncs/i.test(html));
          const requests = performance.getEntriesByType("resource")
            .map((entry) => entry.name)
            .filter((url) => /cjdropshipping|aliyuncs/i.test(url));
          return markup.concat(requests);
        })()
      JAVASCRIPT
      assert_empty violations, "#{viewport} exposed supplier media: #{violations.inspect}"
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
