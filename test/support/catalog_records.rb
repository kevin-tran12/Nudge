module TestSupport
  module CatalogRecords
    def create_cj_supplier
      Supplier.find_or_create_by!(key: "cj") do |supplier|
        supplier.display_name = "CJ Dropshipping"
        supplier.adapter_version = "1"
        supplier.api_version = "v1"
        supplier.status = "active"
      end
    end

    def clear_catalog_records
      CartMutation.delete_all if defined?(CartMutation)
      CartItem.delete_all if defined?(CartItem)
      Cart.delete_all if defined?(Cart)
      SupplierVariant.delete_all if defined?(SupplierVariant)
      SupplierProduct.delete_all if defined?(SupplierProduct)
      ProductVariant.delete_all if defined?(ProductVariant)
      Product.delete_all if defined?(Product)
      Supplier.delete_all if defined?(Supplier)
    end
  end
end
