module Agents
  module Tools
    # Correlates Search::LexicalRetrieval hits (local product ids) back to a local
    # Product/ProductVariant pair and the matching Catalog::ProductReader DTO, so tools
    # can project or evaluate against real catalog facts without duplicating this
    # id-correlation lookup. Preserves the caller's item order -- it never reorders or
    # ranks; a candidate is simply dropped (never fabricated) when it cannot be resolved.
    #
    # CAT-DB-READER-01: the id passed to product_reader.detail must match that reader's
    # own ID_SCHEME. SupplierProduct#external_product_id is a CJ external id, which only
    # a :supplier_external reader accepts; under :local_public_id (Catalog::DatabaseProductReader)
    # that id fails the reader's own id_pattern check, detail raises invalid_input, and
    # every real, imported product was silently dropped as an unresolved candidate. For
    # :local_public_id the already-loaded Product#public_id is the reader's id directly.
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
        catalog_ids = reader_ids_by_product(product_ids, products)

        catalog_cache = {}
        items.filter_map do |item|
          product = products[item.product_id]
          next unless product

          catalog_id = catalog_ids[item.product_id]
          next unless catalog_id

          catalog_product = catalog_cache.fetch(catalog_id) { catalog_cache[catalog_id] = fetch_catalog_product(catalog_id) }
          next unless catalog_product

          variant = product.product_variants.order(:id).first
          catalog_variant = variant ? catalog_product.variants.first : nil

          Candidate.new(product: product, variant: variant, catalog_product: catalog_product, catalog_variant: catalog_variant)
        end
      end

      private
        # Under :local_public_id every already-loaded Product row IS synced by
        # definition (Catalog::DatabaseProductReader reads these exact rows), so its
        # own public_id is the reader id -- no SupplierProduct hop needed. Under
        # :supplier_external, SupplierProduct is still the only place that id lives.
        def reader_ids_by_product(product_ids, products)
          if local_public_id_scheme?
            products.transform_values(&:public_id)
          else
            SupplierProduct.where(product_id: product_ids).order(:supplier_id)
              .each_with_object({}) { |row, memo| memo[row.product_id] ||= row.external_product_id }
          end
        end

        # Own-class check only (not inherited): a reader that never declares ID_SCHEME
        # (e.g. a bare test double) is treated as :supplier_external, matching this
        # resolver's behavior before CAT-DB-READER-01 rather than raising on it.
        def local_public_id_scheme?
          klass = @product_reader.class
          klass.const_defined?(:ID_SCHEME, false) && klass::ID_SCHEME == :local_public_id
        end

        def fetch_catalog_product(catalog_id)
          @product_reader.detail(id: catalog_id)
        rescue Catalog::ProductReader::Error
          nil
        end
    end
  end
end
