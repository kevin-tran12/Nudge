# Resolves the same supplier-facing catalog identifiers already surfaced by
# Catalog::ProductReader (product pages, search_products, get_product_details --
# see AGENTS.md required reading #4) to the local ProductVariant row cart_items
# must reference. The catalog reader is fixture/CJ-backed and does not yet run
# through the CAT-IMPORT-01 sync pipeline for these ids, so no local row exists
# the first time a given variant is added to a cart. This resolver lazily
# creates the minimal Product/ProductVariant/SupplierProduct/SupplierVariant
# rows needed, keyed by the existing (supplier_id, external_variant_id) unique
# index SupplierVariant already carries for exactly this purpose -- it performs
# no sync_runs/checkpoint/observation bookkeeping and is not a substitute for
# CAT-IMPORT-01. Recorded as a launch-readiness decision under AUTH-001 in
# .planning/DECISIONS.md.
#
# Price/availability always come from this call's fresh reader response, never
# from a stored/local value and never from caller input.
class Cart::CatalogVariantResolver
  SUPPLIER_KEY = "cj"
  # Matches Integrations::Cj::Normalizer's fixed provenance and the values
  # db/seeds.rb and the CAT-IMPORT-01 tests already use for this same
  # registry row, so a row created by either path is interchangeable.
  SUPPLIER_ADAPTER_VERSION = "1"
  SUPPLIER_API_VERSION = "v1"

  Resolution = Data.define(:product_variant, :price, :availability)

  def initialize(product_reader: Catalog::FixtureProductReader.new)
    @product_reader = product_reader
  end

  def call(catalog_product_id:, catalog_variant_id:)
    raise Cart::Error.new(:invalid_input) unless catalog_product_id.is_a?(String) && catalog_variant_id.is_a?(String)

    product = @product_reader.detail(id: catalog_product_id)
    variant = product.variants.find { |candidate| candidate.id == catalog_variant_id }
    raise Cart::Error.new(:not_found) unless variant

    product_variant = find_or_create_local_variant!(product, variant)
    Resolution.new(product_variant: product_variant, price: variant.price, availability: variant.availability).freeze
  rescue Catalog::ProductReader::Error => error
    raise Cart::Error.new(error.code == :not_found ? :not_found : :variant_unavailable)
  end

  private
    def supplier
      @supplier ||= Supplier.find_by(key: SUPPLIER_KEY) || create_supplier!
    end

    def create_supplier!
      Supplier.create!(
        key: SUPPLIER_KEY, display_name: "CJ Dropshipping",
        adapter_version: SUPPLIER_ADAPTER_VERSION, api_version: SUPPLIER_API_VERSION, status: "active"
      )
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      Supplier.find_by(key: SUPPLIER_KEY) || raise(Cart::Error.new(:catalog_not_configured))
    end

    def find_or_create_local_variant!(product, variant)
      existing = SupplierVariant.find_by(supplier: supplier, external_variant_id: variant.id)
      return existing.product_variant if existing

      ActiveRecord::Base.transaction(requires_new: true) do
        create_local_variant!(product, variant)
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      SupplierVariant.find_by(supplier: supplier, external_variant_id: variant.id)&.product_variant ||
        raise(Cart::Error.new(:variant_unavailable))
    end

    def create_local_variant!(product, variant)
      now = Time.current
      supplier_product = SupplierProduct.find_by(supplier: supplier, external_product_id: product.id)
      local_product = supplier_product&.product
      local_product ||= Product.create!(
        title: product.title.presence || "Untitled product",
        description: product.description || "",
        status: "active"
      )
      supplier_product ||= SupplierProduct.create!(
        supplier: supplier, product: local_product, external_product_id: product.id,
        status: "observed", first_seen_at: now, last_seen_at: now, adapter_version: supplier.adapter_version
      )

      local_variant = ProductVariant.create!(
        product: local_product, title: variant.title.presence || "Variant",
        option_schema_version: 1, status: "active"
      )
      SupplierVariant.create!(
        supplier: supplier, product_variant: local_variant, supplier_product: supplier_product,
        external_variant_id: variant.id, status: "observed", first_seen_at: now, last_seen_at: now
      )
      local_variant
    end
end
