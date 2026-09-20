require "test_helper"

class TailwindFoundationTest < ActiveSupport::TestCase
  test "uses a CSS-first theme and reduced-motion fallback" do
    stylesheet = Rails.root.join("app/assets/tailwind/application.css").read

    assert_includes stylesheet, "@import \"tailwindcss\";"
    assert_includes stylesheet, "@theme {"
    assert_includes stylesheet, "@media (prefers-reduced-motion: reduce)"
    assert_includes stylesheet, "--color-brand-700:"
  end

  test "does not introduce a JavaScript Tailwind configuration" do
    refute Rails.root.join("tailwind.config.js").exist?
    refute Rails.root.join("tailwind.config.cjs").exist?
  end
end
