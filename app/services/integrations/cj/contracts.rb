module Integrations
  module Cj
    module Contracts
      Result = Data.define(:value, :provenance, :request)
      Provenance = Data.define(:provider, :source, :endpoint_key, :adapter_version,
        :payload_version, :payload_sha256, :observed_at, :request_id)
      Money = Data.define(:amount_minor, :currency)
      Measurement = Data.define(:value, :unit)
      Product = Data.define(:external_id, :sku, :title, :description, :image_urls, :variants)
      Variant = Data.define(:external_id, :product_id, :sku, :title, :price, :weight, :length, :width, :height)
      Inventory = Data.define(:variant_id, :warehouse_id, :country_code,
        :total_quantity, :cj_quantity, :factory_quantity, :subwarehouses)
      Subwarehouse = Data.define(:external_id, :cj_quantity, :factory_quantity)
      Freight = Data.define(:service_name, :price, :tax, :clearance_fee, :total_price,
        :delivery_estimate, :kind, :eligibility, :expires_at)

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
end
