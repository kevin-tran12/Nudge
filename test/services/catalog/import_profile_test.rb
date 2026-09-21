require "test_helper"

# CAT-SYNC-01 (Prodigi phase). Catalog::ImportProfile is the seam that lets
# ArtifactImporter/SupplierCapture stop being CJ-only: every CJ literal these
# two classes used to hardcode (validator class, error class, operations,
# stock endpoint key, adapter version) must live on one frozen profile value
# instead, and Catalog::ImportProfiles::CJ must carry exactly today's real
# values so this phase changes no CJ behavior.
class CatalogImportProfileTest < ActiveSupport::TestCase
  test "ImportProfile is a Data type with the documented fields" do
    assert_equal %i[supplier_key provider adapter_version validator_class error_class operations
      stock_endpoint_key fact_extractor].sort, Catalog::ImportProfile.members.sort
  end

  test "Catalog::ImportProfiles::CJ carries CJ's exact current literals" do
    profile = Catalog::ImportProfiles::CJ

    assert_instance_of Catalog::ImportProfile, profile
    assert_equal "cj", profile.supplier_key
    assert_equal :cj, profile.provider
    # The literal every CJ artifact currently carries (Normalizer, db/seeds.rb,
    # Cart::CatalogVariantResolver::SUPPLIER_ADAPTER_VERSION).
    assert_equal "1", profile.adapter_version
    assert_equal Integrations::Cj::RecordArtifactValidator, profile.validator_class
    assert_equal Integrations::Cj::Error, profile.error_class
    assert_equal %i[product inventory], profile.operations
    # The exact hardcoded endpoint_key ArtifactImporter#latest_successful_stock_observation
    # filters stock observations by today.
    assert_equal "product/stock/queryByVid", profile.stock_endpoint_key
    # Unused until a later phase.
    assert_nil profile.fact_extractor
  end

  test "the CJ profile is frozen so a caller cannot mutate the shared instance" do
    assert Catalog::ImportProfiles::CJ.frozen?
  end
end
