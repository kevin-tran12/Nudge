require "test_helper"

# Captured from live CJ responses on 2026-09-20: every reply carries pointsInfo
# and success alongside the documented envelope. An allowlist without them
# rejects every genuine response.
class CjResponseEnvelopeTest < ActiveSupport::TestCase
  LIVE_ENVELOPE_KEYS = %w[code data message pointsInfo requestId result success].freeze

  test "the allowlist matches the live envelope exactly" do
    assert_equal LIVE_ENVELOPE_KEYS.sort,
      Integrations::Cj::RecordArtifactValidator::RESPONSE_KEYS.sort
  end

  test "the quota and success fields the provider actually sends are allowed" do
    %w[pointsInfo success].each do |key|
      assert_includes Integrations::Cj::RecordArtifactValidator::RESPONSE_KEYS, key
    end
  end

  test "an unexpected envelope key is still rejected" do
    %w[token accessToken authorization injected].each do |key|
      refute_includes Integrations::Cj::RecordArtifactValidator::RESPONSE_KEYS, key
    end
  end

  test "a realistic live envelope validates" do
    artifact = {
      "fixture_version" => 1,
      "observed_at" => "2026-09-20T12:00:00Z",
      "request" => { "variant_id" => "2609161110071618400" },
      "response" => {
        "code" => 200, "result" => true, "message" => "Success",
        "requestId" => "abc-123", "success" => true,
        "pointsInfo" => { "points" => 10, "remaining" => 1490 },
        "data" => [ {
          "vid" => "2609161110071618400", "areaId" => "1", "areaEn" => "China Warehouse",
          "countryCode" => "CN", "totalInventoryNum" => 100, "cjInventoryNum" => 60,
          "factoryInventoryNum" => 40, "storageNum" => 100,
          "stock" => [ { "stockId" => "s-1", "inventory" => 60, "factoryInventory" => 40 } ]
        } ]
      }
    }.to_json

    result = Integrations::Cj::RecordArtifactValidator.new.read(operation: :inventory, artifact_bytes: artifact)

    assert_equal :inventory, result.operation
  end
end
