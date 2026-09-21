require "test_helper"

# CAT-MEDIA-01 (Prodigi phase). FixtureProductReader::APPROVED_MEDIA_HOSTS
# used to be the one place the CJ CDN allowlist lived, and both
# ArtifactImporter's media-url validator and Catalog::DatabaseProductReader
# enforced it by reference -- a second supplier's media host could never
# pass. Catalog::MediaHosts.approved centralizes it and adds one optional
# extra host read from Rails.application.config.x.catalog, so an unset
# config is byte-for-byte the same CJ-only list as before.
class CatalogMediaHostsTest < ActiveSupport::TestCase
  # Mirrors test/services/integrations/cj/media_host_allowlist_test.rb, which
  # pins Integrations::Cj::Normalizer::MEDIA_HOSTS and
  # Catalog::FixtureProductReader::APPROVED_MEDIA_HOSTS to this exact list;
  # that pre-existing assertion must keep passing unchanged.
  CJ_HOSTS = %w[
    cf.cjdropshipping.com
    oss-cf.cjdropshipping.com
    oss.cjdropshipping.com
    cc-west-usa.oss-us-west-1.aliyuncs.com
    cj-product-center.oss-accelerate.aliyuncs.com
  ].freeze

  ConfigDouble = Struct.new(:asset_host)

  setup { @previous_catalog_config = Rails.application.config.x.catalog }
  teardown { Rails.application.config.x.catalog = @previous_catalog_config }

  test "the CJ CDN hosts are always approved" do
    CJ_HOSTS.each { |host| assert_includes Catalog::MediaHosts.approved, host }
  end

  test "an unset asset host config falls back to exactly the CJ-only list" do
    Rails.application.config.x.catalog = nil
    assert_equal CJ_HOSTS.sort, Catalog::MediaHosts.approved.sort
  end

  test "a configured asset host is approved in addition to the CJ hosts" do
    Rails.application.config.x.catalog = ConfigDouble.new("assets.example-supplier.test")

    approved = Catalog::MediaHosts.approved
    assert_includes approved, "assets.example-supplier.test"
    CJ_HOSTS.each { |host| assert_includes approved, host }
  end

  test "an unconfigured (blank) asset host does not widen the CJ-only list" do
    Rails.application.config.x.catalog = ConfigDouble.new(nil)
    assert_equal CJ_HOSTS.sort, Catalog::MediaHosts.approved.sort
  end
end
