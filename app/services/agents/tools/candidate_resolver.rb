module Agents
  module Tools
    # Correlates Search::LexicalRetrieval hits (local product ids) back to a local
    # Product/ProductVariant pair and the matching Catalog::ProductReader DTO, so tools
    # can project or evaluate against real catalog facts without duplicating this
    # id-correlation lookup. Preserves the caller's item order -- it never reorders or
    # ranks; a candidate is simply dropped (never fabricated) when it cannot be resolved.
    class CandidateResolver
      Candidate = Data.define(:product, :variant, :catalog_product, :catalog_variant)

      def initialize(product_reader:)
        @product_reader = product_reader
      end

      # items: an ordered array of Search::LexicalRetrieval::Item.
      def resolve(items)
        product_ids = items.map(&:product_id).compact.uniq
        return [] if product_ids.empty?

        products = Product.where(id: product_ids).index_by(&:id)
        external_ids = SupplierProduct.where(product_id: product_ids).order(:supplier_id)
          .each_with_object({}) { |row, memo| memo[row.product_id] ||= row.external_product_id }

        catalog_cache = {}
        items.filter_map do |item|
          product = products[item.product_id]
          next unless product

          external_id = external_ids[item.product_id]
          next unless external_id

          catalog_product = catalog_cache.fetch(external_id) { catalog_cache[external_id] = fetch_catalog_product(external_id) }
          next unless catalog_product

          variant = product.product_variants.order(:id).first
          catalog_variant = variant ? catalog_product.variants.first : nil

          Candidate.new(product: product, variant: variant, catalog_product: catalog_product, catalog_variant: catalog_variant)
        end
      end

      private
        def fetch_catalog_product(external_id)
          @product_reader.detail(id: external_id)
        rescue Catalog::ProductReader::Error
          nil
        end
    end
  end
end
