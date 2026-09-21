module Catalog
  module ImportProfiles
    # Exactly today's CJ literals -- this phase changes no CJ behavior.
    CJ = ImportProfile.new(
      supplier_key: "cj",
      provider: :cj,
      adapter_version: "1",
      validator_class: Integrations::Cj::RecordArtifactValidator,
      error_class: Integrations::Cj::Error,
      operations: %i[product inventory],
      stock_endpoint_key: "product/stock/queryByVid",
      # Unused until a later phase.
      fact_extractor: nil
    ).freeze
  end
end
