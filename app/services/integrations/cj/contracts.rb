module Integrations
  module Cj
    module Contracts
      # CAT-SYNC-01 (Prodigi phase). These six shapes are not CJ-specific --
      # ArtifactImporter only ever reads the generic shape, never a CJ-only
      # field -- so they alias Integrations::Contracts instead of forking it.
      # Integrations::Cj::Contracts::Product and Integrations::Contracts::Product
      # are the exact same class, not merely equal instances.
      Result = Integrations::Contracts::Result
      Provenance = Integrations::Contracts::Provenance
      Money = Integrations::Contracts::Money
      Measurement = Integrations::Contracts::Measurement
      Product = Integrations::Contracts::Product
      Variant = Integrations::Contracts::Variant

      # CJ-only shapes: nothing about them is shared with another supplier,
      # so they stay defined only in this namespace.
      Inventory = Data.define(:variant_id, :warehouse_id, :country_code,
        :total_quantity, :cj_quantity, :factory_quantity, :subwarehouses)
      Subwarehouse = Data.define(:external_id, :cj_quantity, :factory_quantity)
      Freight = Data.define(:service_name, :price, :tax, :clearance_fee, :total_price,
        :delivery_estimate, :kind, :eligibility, :expires_at)
      ProductSummary = Data.define(:external_id, :sku, :title, :image_url, :price)
      ProductListPage = Data.define(:products, :page, :page_size, :total_count, :has_more)

      def self.deep_freeze(value)
        Integrations::Contracts.deep_freeze(value)
      end
    end
  end
end
