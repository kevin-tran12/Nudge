module Integrations
  # CAT-SYNC-01 (Prodigi phase). The DTOs Catalog::ArtifactImporter actually
  # consumes (Result/Provenance/Money/Measurement/Product/Variant) were
  # CJ-namespaced even though nothing about their shape is CJ-specific. They
  # live here instead, and Integrations::Cj::Contracts aliases them rather
  # than forking them, so a second supplier can hand the importer the same
  # shape without reaching into the CJ namespace. Provider-specific shapes
  # (CJ's Inventory, Subwarehouse, Freight, ProductSummary, ProductListPage)
  # stay defined only in their own namespace -- nothing about them is shared.
  module Contracts
    Result = Data.define(:value, :provenance, :request)
    Provenance = Data.define(:provider, :source, :endpoint_key, :adapter_version,
      :payload_version, :payload_sha256, :observed_at, :request_id)
    Money = Data.define(:amount_minor, :currency)
    Measurement = Data.define(:value, :unit)

    # attributes: a small allowlisted hash for supplier-native structured
    # values that don't fit a typed field (seller identity, popularity
    # count, material, ships-to countries) -- not free text. Defaults to {}
    # so existing callers (Integrations::Cj::Normalizer never passes it)
    # keep working unchanged.
    Product = Data.define(:external_id, :sku, :title, :description, :image_urls, :variants, :attributes) do
      def initialize(attributes: {}, **rest)
        super(attributes:, **rest)
      end
    end

    # options sits alongside the pre-existing option_label field: a
    # structured supplement, not a replacement. Defaults to {} for the same
    # reason as Product#attributes.
    Variant = Data.define(:external_id, :product_id, :sku, :title, :option_label, :options, :price,
      :weight, :length, :width, :height) do
      def initialize(options: {}, **rest)
        super(options:, **rest)
      end
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
