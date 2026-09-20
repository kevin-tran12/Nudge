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

  test "shared controls and navigation have contrasting focus indicators" do
    %w[shared/_button shared/_form_field layouts/application].each do |view|
      template = Rails.root.join("app/views/#{view}.html.erb").read
      colors = template.scan(/focus(?:-visible)?:ring-(?!offset-)([a-z][a-z0-9-]*)/).flatten.uniq

      assert colors.any?, "#{view} must provide a focus indicator"
      colors.each { |color| assert_control_contrast(color, "#{view} focus indicator") }
    end
  end

  test "empty form fields have a contrasting boundary" do
    template = Rails.root.join("app/views/shared/_form_field.html.erb").read
    colors = template.scan(/(?<![:\w-])border-([a-z][a-z0-9-]*)/).flatten.uniq

    assert colors.any?, "Empty form fields must have a visible boundary"
    colors.each { |color| assert_control_contrast(color, "Empty form field boundary") }
  end

  private

  def assert_control_contrast(color, description)
    %w[surface canvas].each do |background|
      light, dark = [ relative_luminance(color), relative_luminance(background) ].sort.reverse
      ratio = (light + 0.05) / (dark + 0.05)

      assert_operator ratio, :>=, 3.0,
        "#{description} (#{color}) has #{ratio.round(2)}:1 contrast against #{background}; at least 3:1 is required"
    end
  end

  def relative_luminance(color)
    theme_colors = Rails.root.join("app/assets/tailwind/application.css").read
      .scan(/--color-([a-z0-9-]+):\s*#([0-9a-f]{6});/i).to_h
    channels = theme_colors.fetch(color).scan(/../).map do |channel|
      value = channel.to_i(16) / 255.0
      value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055)**2.4
    end

    channels.zip([ 0.2126, 0.7152, 0.0722 ]).sum { |value, weight| value * weight }
  end
end
