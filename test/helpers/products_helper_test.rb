require "test_helper"

class ProductsHelperTest < ActionView::TestCase
  test "formats exact integer minor units without treating unknown as zero" do
    known = price(state: :known, amount_minor: 1_234_567, currency: "USD")
    zero = price(state: :known, amount_minor: 0, currency: "USD")
    unknown = price(state: :unknown, amount_minor: nil, currency: nil)

    assert_equal "Illustrative price: USD 12,345.67", catalog_price_label(known)
    assert_equal "Illustrative price: USD 0.00", catalog_price_label(zero)
    assert_equal "Illustrative price unavailable", catalog_price_label(unknown)
    refute_match(/0|free/i, catalog_price_label(unknown))
  end

  test "describes observed availability without promising reservation or eligibility" do
    assert_equal "Observed availability: 9 units observed", catalog_availability_label(availability(:available, 9))
    assert_equal "Observed availability: unavailable when observed", catalog_availability_label(availability(:unavailable, 0))
    assert_equal "Availability unknown", catalog_availability_label(availability(:unknown, nil))
    refute_match(/reserved|eligible|guaranteed/i, catalog_availability_label(availability(:available, 9)))
  end

  test "formats measurements without converting unknown to zero" do
    known = Catalog::ProductReader::Measurement.new(state: :known, value: BigDecimal("250.5"), unit: "g")
    unknown = Catalog::ProductReader::Measurement.new(state: :unknown, value: nil, unit: nil)

    assert_equal "250.5 g", catalog_measurement(known)
    assert_equal "Unknown", catalog_measurement(unknown)
  end

  private
    def price(state:, amount_minor:, currency:)
      Catalog::ProductReader::Price.new(state:, amount_minor:, currency:, freshness: freshness)
    end

    def availability(state, quantity)
      Catalog::ProductReader::Availability.new(state:, quantity:, reason: :observed, freshness: freshness)
    end

    def freshness
      Catalog::ProductReader::Freshness.new(state: :observed, observed_at: Time.iso8601("2026-09-20T00:00:00Z"))
    end
end
