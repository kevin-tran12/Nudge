require "test_helper"

# The media-host allowlist is an SSRF and content-injection control on
# attacker-influenced supplier URLs. Widening it for a real provider host must
# not weaken its shape, so this pins both what is allowed and what still is not.
class CjMediaHostAllowlistTest < ActiveSupport::TestCase
  ALLOWED = %w[
    cf.cjdropshipping.com
    oss-cf.cjdropshipping.com
    cc-west-usa.oss-us-west-1.aliyuncs.com
  ].freeze

  test "the normalizer and the reader agree on the approved hosts" do
    assert_equal ALLOWED.sort,
      Integrations::Cj::Normalizer::MEDIA_HOSTS.sort
    assert_equal ALLOWED.sort,
      Catalog::FixtureProductReader::APPROVED_MEDIA_HOSTS.sort
  end

  test "the live CJ product-detail image host is approved" do
    # Verified against a real CJ product/query response: every image URL it
    # returned was served from this host.
    assert_includes Integrations::Cj::Normalizer::MEDIA_HOSTS, "oss-cf.cjdropshipping.com"
  end

  test "hosts outside the supplier CDN are still rejected" do
    [
      "evil.example.com",
      "cjdropshipping.com.evil.example.com",
      "cjdropshipping.com",
      "oss-cf.cjdropshipping.com.attacker.test",
      "localhost",
      "169.254.169.254"
    ].each do |host|
      refute_includes Integrations::Cj::Normalizer::MEDIA_HOSTS, host,
        "#{host} must not be treated as an approved media host"
      refute_includes Catalog::FixtureProductReader::APPROVED_MEDIA_HOSTS, host,
        "#{host} must not be treated as an approved media host"
    end
  end
end
