module ProductsHelper
  def catalog_price_label(price)
    return "Illustrative price unavailable" unless price.state == :known

    major, minor = price.amount_minor.divmod(100)
    "Illustrative price: #{price.currency} #{number_with_delimiter(major)}.#{format('%02d', minor)}"
  end

  def catalog_availability_label(availability)
    case availability.state
    when :available
      "Observed availability: #{number_with_delimiter(availability.quantity)} units observed"
    when :unavailable
      "Observed availability: unavailable when observed"
    else
      "Availability unknown"
    end
  end

  def catalog_availability_tone(availability)
    availability.state == :available ? :success : :warning
  end

  def catalog_measurement(measurement)
    return "Unknown" unless measurement.state == :known

    value = measurement.value.is_a?(BigDecimal) ? measurement.value.to_s("F") : measurement.value.to_s
    "#{value} #{measurement.unit}"
  end

  def catalog_product_price(product)
    product.variants.map(&:price).find { |price| price.state == :known } || product.variants.first&.price
  end

  def catalog_product_availability(product)
    rows = product.variants.map(&:availability)
    rows.find { |availability| availability.state == :available } ||
      rows.find { |availability| availability.state == :unknown } || rows.first
  end
end
