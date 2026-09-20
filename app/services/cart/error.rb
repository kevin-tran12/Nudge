class Cart::Error < StandardError
  CODES = %i[
    invalid_input not_found variant_unavailable quantity_invalid
    mutation_conflict catalog_not_configured conflict
  ].freeze

  attr_reader :code

  def initialize(code)
    raise ArgumentError, "unknown cart error code" unless CODES.include?(code)

    @code = code
    super("Cart: #{code}")
  end

  def as_json(*)
    { "code" => code.to_s }
  end

  def to_json(...)
    as_json.to_json(...)
  end
end
