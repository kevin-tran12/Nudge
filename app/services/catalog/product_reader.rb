module Catalog
  class ProductReader
    MAX_LIMIT = 24

    Page = Data.define(:items, :next_cursor)
    Product = Data.define(:id, :sku, :title, :description, :images, :images_state, :variants, :freshness)
    Image = Data.define(:url, :position)
    Variant = Data.define(:id, :sku, :title, :price, :availability, :weight, :length, :width, :height)
    Price = Data.define(:state, :amount_minor, :currency, :freshness)
    Measurement = Data.define(:state, :value, :unit)
    Availability = Data.define(:state, :quantity, :reason, :freshness)
    Freshness = Data.define(:state, :observed_at)

    class Error < StandardError
      attr_reader :code

      def initialize(code, retryable: false)
        @code = code
        @retryable = retryable
        super("Catalog reader: #{code}")
      end

      def retryable?
        @retryable
      end
    end

    def list(limit: MAX_LIMIT, cursor: nil)
      raise NotImplementedError
    end

    def detail(id:)
      raise NotImplementedError
    end

    def self.deep_freeze(value)
      case value
      when Data
        value.to_h.each_value { |child| deep_freeze(child) }
      when Array
        value.each { |child| deep_freeze(child) }
      when Hash
        value.each { |key, child| deep_freeze(key); deep_freeze(child) }
      end
      value.freeze
    end
  end
end
