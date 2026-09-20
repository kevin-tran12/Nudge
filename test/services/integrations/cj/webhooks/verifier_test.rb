require "test_helper"
require "base64"
require "openssl"

class CjWebhookVerifierTest < ActiveSupport::TestCase
  OPEN_ID = "synthetic-open-id-for-tests"
  FIXTURE = Rails.root.join("test/fixtures/files/cj/webhooks/v1/product-update.json")

  test "verifies the exact raw body and returns a frozen sanitized contract" do
    raw_body = File.binread(FIXTURE)
    result = verifier.call(raw_body:, signature: signature_for(raw_body))

    assert_equal raw_body.b, result.raw_body
    assert_equal Digest::SHA256.hexdigest(raw_body), result.payload_sha256
    assert_equal "fixture-message-001", result.message_id
    assert_equal "PRODUCT", result.message_type
    assert_equal "UPDATE", result.event_type
    assert_equal "product-fixture-001", result.params.fetch("pid")
    assert_predicate result, :frozen?
    assert_predicate result.raw_body, :frozen?
    assert_predicate result.params, :frozen?
    assert_predicate result.params.fetch("supplierText"), :frozen?
  end

  test "rejects body mutation before parsing" do
    raw_body = File.binread(FIXTURE)
    mutated = raw_body.sub("ACTIVE", "PAUSED")

    assert_error(:invalid_signature) do
      verifier.call(raw_body: mutated, signature: signature_for(raw_body))
    end
  end

  test "rejects malformed and noncanonical signatures without exposing inputs" do
    raw_body = File.binread(FIXTURE)

    [ nil, "", "not-base64", Base64.strict_encode64("short") ].each do |signature|
      error = assert_error(:invalid_signature) { verifier.call(raw_body:, signature:) }
      refute_includes error.message, raw_body
      refute_includes error.message, OPEN_ID
      refute_includes error.inspect, OPEN_ID
    end
  end

  test "rejects malformed, missing, and invalid envelope fields after verification" do
    bodies = [
      "not-json",
      "[]",
      '{"messageId":"id","messageType":"PRODUCT","type":"UPDATE"}',
      '{"messageId":"","messageType":"PRODUCT","type":"UPDATE","params":{}}',
      "{\"messageId\":\"id\\u0000\",\"messageType\":\"PRODUCT\",\"type\":\"UPDATE\",\"params\":{}}",
      '{"messageId":"id","messageType":"PRODUCT","type":"UPDATE","params":"not-structured"}'
    ]

    bodies.each do |raw_body|
      assert_error(:malformed_payload) do
        verifier.call(raw_body:, signature: signature_for(raw_body))
      end
    end
  end

  test "rejects oversized bodies before invoking the signature verifier" do
    signature_verifier = Object.new
    signature_verifier.define_singleton_method(:verify) { |**| flunk "signature verifier was called" }
    boundary = Integrations::Cj::Webhooks::Verifier.new(signature_verifier:)
    raw_body = "x" * (Integrations::Cj::Webhooks::Parser::MAX_BODY_BYTES + 1)

    assert_error(:body_too_large) { boundary.call(raw_body:, signature: "unused") }
  end

  test "bounds nested and wide JSON input" do
    nested = '{"messageId":"id","messageType":"PRODUCT","type":"UPDATE","params":' +
      ("[" * 13) + "{}" + ("]" * 13) + "}"
    wide_params = Array.new(501, 0)
    wide = JSON.generate(messageId: "id", messageType: "PRODUCT", type: "UPDATE", params: wide_params)

    [ nested, wide ].each do |raw_body|
      assert_error(:malformed_payload) do
        verifier.call(raw_body:, signature: signature_for(raw_body))
      end
    end
  end

  test "converts injected verifier failures into sanitized fail-closed errors" do
    dependency = Object.new
    dependency.define_singleton_method(:verify) { |**| raise "synthetic-secret provider failure" }
    boundary = Integrations::Cj::Webhooks::Verifier.new(signature_verifier: dependency)
    raw_body = File.binread(FIXTURE)

    error = assert_error(:invalid_signature) do
      boundary.call(raw_body:, signature: signature_for(raw_body))
    end
    refute_includes error.message, "synthetic-secret"
    assert_nil error.cause
  end

  test "requires an injected verifier and validates HMAC configuration" do
    assert_error(:invalid_input) { Integrations::Cj::Webhooks::Verifier.new(signature_verifier: nil) }

    [ nil, "", "x" * 1025 ].each do |open_id|
      error = assert_error(:invalid_input) do
        Integrations::Cj::Webhooks::HmacSignatureVerifier.new(open_id:)
      end
      refute_includes error.inspect, open_id.to_s unless open_id.to_s.empty?
    end
  end

  test "implementation has no environment persistence network or controller dependency" do
    source = Dir[Rails.root.join("app/services/integrations/cj/webhooks/*.rb")].sort.map { |path| File.read(path) }.join("\n")

    %w[ENV ActiveRecord Net::HTTP Faraday HTTPParty Controller Job].each do |forbidden|
      refute_includes source, forbidden
    end
  end

  private
    def verifier
      Integrations::Cj::Webhooks::Verifier.new(
        signature_verifier: Integrations::Cj::Webhooks::HmacSignatureVerifier.new(open_id: OPEN_ID)
      )
    end

    def signature_for(raw_body)
      Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", OPEN_ID, raw_body))
    end

    def assert_error(code, &block)
      error = assert_raises(Integrations::Cj::Webhooks::Error, &block)
      assert_equal code, error.code
      assert_equal "CJ webhook: #{code}", error.message
      error
    end
end
