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
    assert_equal "UPDATE", result.message_type
    assert_equal "PRODUCT", result.event_type
    assert_equal "product-fixture-001", result.params.fetch("pid")
    assert_equal 3, result.params.fetch("productStatus") # CJ's documented on-sale status.
    assert_predicate result, :frozen?
    assert_predicate result.raw_body, :frozen?
    assert_predicate result.params, :frozen?
    assert_predicate result.params.fetch("supplierText"), :frozen?
  end

  test "rejects body mutation before parsing" do
    raw_body = File.binread(FIXTURE)
    mutated = raw_body.sub("product-fixture-001", "product-fixture-002")
    refute_equal raw_body, mutated

    assert_error(:invalid_signature) do
      verifier.call(raw_body: mutated, signature: signature_for(raw_body))
    end
  end

  test "matches the documented standard Base64 HMAC SHA256 vector" do
    # Public example: https://developers.cjdropshipping.com/en/api/start/webhook.html
    dependency = Integrations::Cj::Webhooks::HmacSignatureVerifier.new(open_id: "123")
    raw_body = '{"messageId":"123111","messageType":"INSERT","params":"123","type":"PRODUCT"}'
    signature = "AHxoGFMoS/4mZfJ5vFes5//Pz2QibFQhh3GlrTtnWpk="

    assert dependency.verify(raw_body:, signature:)
    refute dependency.verify(raw_body: raw_body + "\n", signature:)
    refute dependency.verify(raw_body:, signature: signature.delete_suffix("="))
    refute dependency.verify(raw_body:, signature: signature + "\n")
  end

  test "signing dependencies expose no keys through direct or nested serialization" do
    dependency = Integrations::Cj::Webhooks::HmacSignatureVerifier.new(open_id: OPEN_ID)
    boundary = Integrations::Cj::Webhooks::Verifier.new(signature_verifier: dependency)

    [ dependency, boundary ].each do |value|
      refute_includes value.inspect, OPEN_ID
      assert_equal({ "configured" => true }, value.as_json)
      serialized_forms(value).each { |serialized| refute_includes serialized, OPEN_ID }
    end
  end

  test "result inspection and JSON expose only metadata while retaining explicit immutable payload access" do
    secret = "synthetic-sensitive-payload"
    raw_body = JSON.generate(messageId: "id", messageType: "UPDATE", type: "PRODUCT", params: { openId: secret })
    result = verifier.call(raw_body:, signature: signature_for(raw_body))
    metadata = {
      "payload_sha256" => Digest::SHA256.hexdigest(raw_body),
      "message_id" => "id", "message_type" => "UPDATE", "event_type" => "PRODUCT"
    }

    assert_equal raw_body, result.raw_body
    assert_equal secret, result.params.fetch("openId")
    assert_predicate result.params.fetch("openId"), :frozen?
    assert_equal metadata, result.as_json
    assert_equal metadata, JSON.parse(result.to_json)
    assert_equal({ "value" => [ metadata ] }, JSON.parse(ActiveSupport::JSON.encode(value: [ result ])))
    refute_includes result.inspect, secret
    serialized_forms(result).each do |serialized|
      refute_includes serialized, secret
      refute_includes serialized, "raw_body"
      refute_includes serialized, "params"
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
      '{"messageId":"id","messageType":"UPDATE","type":"PRODUCT"}',
      '{"messageId":"","messageType":"UPDATE","type":"PRODUCT","params":{}}',
      "{\"messageId\":\"id\\u0000\",\"messageType\":\"UPDATE\",\"type\":\"PRODUCT\",\"params\":{}}",
      '{"messageId":"id","messageType":"UPDATE","type":"PRODUCT","params":"not-structured"}'
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
    nested = '{"messageId":"id","messageType":"UPDATE","type":"PRODUCT","params":' +
      ("[" * 13) + "{}" + ("]" * 13) + "}"
    wide_params = Array.new(501, 0)
    wide = JSON.generate(messageId: "id", messageType: "UPDATE", type: "PRODUCT", params: wide_params)

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

  test "reconstructs classified verifier and parser errors without retaining sensitive causes" do
    raw_body = File.binread(FIXTURE)

    { verify: :invalid_signature, call: :malformed_payload }.each do |method, code|
      original = Integrations::Cj::Webhooks::Error.new(code)
      original.set_backtrace([ "synthetic-secret dependency detail" ])
      dependency = Object.new
      dependency.define_singleton_method(method) do |**|
        raise original, cause: RuntimeError.new("synthetic-secret provider cause")
      end
      boundary = if method == :verify
        Integrations::Cj::Webhooks::Verifier.new(signature_verifier: dependency)
      else
        Integrations::Cj::Webhooks::Verifier.new(
          signature_verifier: Integrations::Cj::Webhooks::HmacSignatureVerifier.new(open_id: OPEN_ID),
          parser: dependency
        )
      end

      error = assert_error(code) { boundary.call(raw_body:, signature: signature_for(raw_body)) }
      refute_same original, error
      assert_nil error.cause
      refute_includes error.full_message, "synthetic-secret"
    end
  end

  test "rejects positive and negative numeric overflow without rejecting finite numbers" do
    [ "1e400", "-1e400" ].each do |number|
      raw_body = %({"messageId":"id","messageType":"UPDATE","type":"PRODUCT","params":{"value":#{number}}})
      error = assert_error(:malformed_payload) { verifier.call(raw_body:, signature: signature_for(raw_body)) }
      assert_nil error.cause
    end

    raw_body = '{"messageId":"id","messageType":"UPDATE","type":"PRODUCT","params":{"integer":3,"float":1.5}}'
    result = verifier.call(raw_body:, signature: signature_for(raw_body))
    assert_equal({ "integer" => 3, "float" => 1.5 }, result.params)
  end

  test "rejects duplicate keys at root and nested levels with sanitized errors" do
    bodies = [
      '{"messageId":"id","messageId":"duplicate","messageType":"UPDATE","type":"PRODUCT","params":{}}',
      '{"messageId":"id","messageType":"UPDATE","type":"PRODUCT","params":{"value":1,"value":2}}'
    ]

    bodies.each do |raw_body|
      error = assert_error(:malformed_payload) { verifier.call(raw_body:, signature: signature_for(raw_body)) }
      assert_nil error.cause
    end
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

    def serialized_forms(value)
      [
        value.as_json.to_json,
        value.to_json,
        JSON.generate(value),
        ActiveSupport::JSON.encode(value),
        { value: [ value ] }.to_json,
        ActiveSupport::JSON.encode(value: [ value ])
      ]
    end
end
