require "application_system_test_case"

class ApplicationShellTest < ApplicationSystemTestCase
  VIEWPORTS = {
    "compact phone" => [ 320, 720 ],
    "phone" => [ 375, 812 ],
    "tablet" => [ 768, 1024 ],
    "desktop" => [ 1280, 900 ]
  }.freeze

  test "application shell remains accessible at its supported viewports" do
    VIEWPORTS.each do |name, (width, height)|
      set_viewport(width, height)
      visit root_path

      assert_equal width, page.evaluate_script("window.innerWidth"), "#{name} viewport width"
      assert_shell_landmarks(name)
      assert_no_horizontal_overflow(name)
      assert_minimum_target_sizes(name)
    end
  end

  test "keyboard users can reveal and follow the skip link" do
    set_viewport(320, 720)
    visit root_path

    send_key(:tab)

    assert_equal "Skip to content", page.evaluate_script("document.activeElement.textContent.trim()")
    focus = wait_for_skip_link_transition

    assert_operator focus.fetch("top"), :>=, 0
    assert_operator focus.fetch("left"), :>=, 0
    assert_operator focus.fetch("right"), :<=, 320
    assert_operator focus.fetch("bottom"), :<=, 720
    assert(
      focus.fetch("outline") != "none" || focus.fetch("shadow") != "none",
      "focused skip link must have a visible focus indicator"
    )

    send_key(:enter)

    assert_equal "#main-content", page.evaluate_script("window.location.hash")
    assert_equal "main-content", page.evaluate_script("document.activeElement.id")
  end

  private

  def set_viewport(width, height)
    page.current_window.resize_to(width, height)
    actual_width = page.evaluate_script("window.innerWidth")
    actual_height = page.evaluate_script("window.innerHeight")

    page.current_window.resize_to(
      width + (width - actual_width),
      height + (height - actual_height)
    )
  end

  def assert_shell_landmarks(viewport)
    assert_selector "header", count: 1
    assert_selector "nav[aria-label='Primary navigation']", count: 1
    assert_selector "main#main-content", count: 1
    assert_selector "footer", count: 1
    assert_selector "h1", count: 1
  rescue Minitest::Assertion => error
    raise Minitest::Assertion, "#{viewport}: #{error.message}"
  end

  def assert_no_horizontal_overflow(viewport)
    overflow = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        const root = document.documentElement;
        const width = root.clientWidth;
        const offenders = Array.from(document.body.querySelectorAll("*"))
          .filter((element) => {
            const rect = element.getBoundingClientRect();
            return rect.left < -0.5 || rect.right > width + 0.5;
          })
          .map((element) => ({
            element: element.tagName.toLowerCase(),
            id: element.id,
            classes: element.className.toString(),
            left: element.getBoundingClientRect().left,
            right: element.getBoundingClientRect().right
          }));

        return {
          clientWidth: width,
          scrollWidth: root.scrollWidth,
          offenders: offenders
        };
      })()
    JAVASCRIPT

    assert_operator(
      overflow.fetch("scrollWidth"),
      :<=,
      overflow.fetch("clientWidth"),
      "#{viewport} has horizontal overflow: #{overflow.fetch('offenders').inspect}"
    )
  end

  def assert_minimum_target_sizes(viewport)
    targets = page.evaluate_script(<<~JAVASCRIPT)
      Array.from(document.querySelectorAll("a[href], button, input, select, textarea, summary, [tabindex]:not([tabindex='-1'])"))
        .filter((element) => !element.disabled && getComputedStyle(element).visibility !== "hidden")
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            name: element.getAttribute("aria-label") || element.textContent.trim() || element.name || element.id,
            width: rect.width,
            height: rect.height
          };
        });
    JAVASCRIPT

    assert_operator targets.length, :>, 0, "#{viewport} should contain interactive controls"

    targets.each do |target|
      assert_operator target.fetch("width"), :>=, 44,
        "#{viewport}: #{target.fetch('name').inspect} is only #{target.fetch('width')}px wide"
      assert_operator target.fetch("height"), :>=, 44,
        "#{viewport}: #{target.fetch('name').inspect} is only #{target.fetch('height')}px high"
    end
  end

  def send_key(key)
    page.driver.browser.action.send_keys(key).perform
  end

  def wait_for_skip_link_transition
    focus = nil

    page.document.synchronize do
      focus = page.evaluate_script(<<~JAVASCRIPT)
        (() => {
          const element = document.activeElement;
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return {
            top: rect.top,
            left: rect.left,
            right: rect.right,
            bottom: rect.bottom,
            outline: style.outlineStyle,
            shadow: style.boxShadow
          };
        })()
      JAVASCRIPT

      raise Capybara::ExpectationNotMet, "skip link transition has not completed" if focus.fetch("top").negative?
    end

    focus
  end
end
