module TestSupport
  module ShoppingRecords
    REFERENCE_TIME = Time.utc(2026, 9, 20, 12, 0, 0)

    def create_shopping_session_for_shopping(status: "active", started_at: REFERENCE_TIME - 1.hour,
      expires_at: REFERENCE_TIME + 2.hours)
      ShoppingSession.create!(status:, started_at:, last_activity_at: REFERENCE_TIME - 1.minute, expires_at:)
    end

    def create_local_product(title: "Storage bin")
      Product.create!(title:, description: "", status: "draft")
    end

    def create_local_variant(product:, title: "Default variant")
      ProductVariant.create!(product:, title:, option_summary: {}, option_schema_version: 1)
    end

    def requirement_payload(requirement_key:, operator: "lte", kind: "hard", value_json: { "value" => 1 },
      value_schema_version: 1, source: "user_explicit", confidence: 1.0, importance: 1.0,
      needs_clarification: false)
      {
        requirement_key:, operator:, kind:, value_json:, value_schema_version:, source:,
        confidence:, importance:, needs_clarification:
      }
    end

    def known_price(amount_minor:, currency: "USD")
      Catalog::ProductReader::Price.new(state: :known, amount_minor:, currency:,
        freshness: known_freshness)
    end

    def unknown_price
      Catalog::ProductReader::Price.new(state: :unknown, amount_minor: nil, currency: nil,
        freshness: unknown_freshness)
    end

    def known_availability(state:, quantity: 1)
      Catalog::ProductReader::Availability.new(state:, quantity:, reason: :observed, freshness: known_freshness)
    end

    def unknown_availability
      Catalog::ProductReader::Availability.new(state: :unknown, quantity: nil, reason: :not_observed,
        freshness: unknown_freshness)
    end

    def known_measurement(value:, unit: "g")
      Catalog::ProductReader::Measurement.new(state: :known, value:, unit:)
    end

    def unknown_measurement
      Catalog::ProductReader::Measurement.new(state: :unknown, value: nil, unit: nil)
    end

    def known_freshness
      Catalog::ProductReader::Freshness.new(state: :observed, observed_at: REFERENCE_TIME)
    end

    def unknown_freshness
      Catalog::ProductReader::Freshness.new(state: :unknown, observed_at: nil)
    end

    def catalog_variant(price: known_price(amount_minor: 1_000), availability: known_availability(state: :available),
      weight: unknown_measurement, length: unknown_measurement, width: unknown_measurement,
      height: unknown_measurement, id: "catalog-variant-1")
      Catalog::ProductReader::Variant.new(id:, sku: nil, title: nil, price:, availability:, weight:, length:,
        width:, height:)
    end

    def catalog_product(id: "catalog-product-1", variants: [])
      Catalog::ProductReader::Product.new(id:, sku: nil, title: "Fixture product", description: nil,
        images: [], images_state: :unknown, variants:, freshness: known_freshness)
    end
  end
end
