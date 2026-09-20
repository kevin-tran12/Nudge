require "test_helper"

class Agents::Tools::ProductProjectionTest < ActiveSupport::TestCase
  FORBIDDEN_KEY_FRAGMENTS = %w[
    email phone address coordinate lat lng latitude longitude card stripe
    google oidc token password ip_address device fingerprint abuse reputation
    turnstile log admin secret env key_digest public_id user_id session_id
  ].freeze

  test "product summary and detail projections never expose a forbidden field" do
    product = Catalog::FixtureProductReader.new.detail(id: "00001234")

    [ Agents::Tools::ProductProjection.summary(product), Agents::Tools::ProductProjection.detail(product) ].each do |projection|
      refute_forbidden(projection)
    end
  end

  test "summary and detail projections are exact allow-lists" do
    product = Catalog::FixtureProductReader.new.detail(id: "00001234")

    assert_equal %w[availability id price title], Agents::Tools::ProductProjection.summary(product).keys.sort
    assert_equal %w[description id images title variants],
      Agents::Tools::ProductProjection.detail(product).keys.sort
  end

  private
    def refute_forbidden(value, path = "$")
      case value
      when Hash
        value.each do |key, child|
          key_text = key.to_s.downcase
          FORBIDDEN_KEY_FRAGMENTS.each do |fragment|
            refute key_text.include?(fragment), "forbidden field '#{key}' present at #{path}"
          end
          refute_forbidden(child, "#{path}.#{key}")
        end
      when Array
        value.each_with_index { |child, index| refute_forbidden(child, "#{path}[#{index}]") }
      end
    end
end
