module Catalog
  # CAT-SYNC-01 (Prodigi phase). Catalog::ArtifactImporter and
  # Catalog::SupplierCapture used to hardcode every CJ literal (validator
  # class, error class, operations, stock endpoint key, adapter version).
  # A profile carries them instead, so a second supplier can be added by
  # defining a new profile rather than forking either class. See
  # Catalog::ImportProfiles for the concrete profiles.
  ImportProfile = Data.define(:supplier_key, :provider, :adapter_version, :validator_class,
    :error_class, :operations, :stock_endpoint_key, :fact_extractor)
end
