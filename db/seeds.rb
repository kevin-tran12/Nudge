# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# CJ Dropshipping is the one persisted supplier registry binding (TRD §6; SCHEMA.md
# `suppliers`). Its key is immutable and server-owned. adapter_version/api_version match
# what Integrations::Cj::Normalizer and the CAT-IMPORT-01 tests already use, so any local
# catalog rows a package lazily creates against this supplier (e.g. Cart::CatalogVariantResolver)
# stay compatible with the real importer's supplier-lock check.
Supplier.find_or_create_by!(key: "cj") do |supplier|
  supplier.display_name = "CJ Dropshipping"
  supplier.adapter_version = "1"
  supplier.api_version = "v1"
  supplier.status = "active"
end
