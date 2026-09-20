require "test_helper"
require "digest"
require "json"
require "net/http"
require "stringio"
require "yaml"

class CjRecordArtifactValidatorTest < ActiveSupport::TestCase
  FIXTURES = Rails.root.join("test/fixtures/files/cj/v1")

  test "builds immutable deterministic replayable v1 artifacts for approved operations" do
    %i[product inventory freight].each do |operation|
      fixture = fixture_for(operation)
      raw_body = JSON.generate(fixture.fetch("response"))

      first = validator.call(operation:, request: fixture.fetch("request"), raw_body:,
        observed_at: fixture.fetch("observed_at"))
      second = validator.call(operation:, request: fixture.fetch("request"), raw_body:,
        observed_at: fixture.fetch("observed_at"))

      assert_equal first, second
      assert_equal operation, first.operation
      assert_equal Digest::SHA256.hexdigest(first.artifact_bytes), first.artifact_sha256
      assert_equal first.normalized.provenance, first.provenance
      assert_equal :record_artifact, first.provenance.source
      assert_equal first.artifact_sha256, first.provenance.payload_sha256
      assert first.frozen?
      assert first.artifact_bytes.frozen?
      assert first.artifact_sha256.frozen?
      assert first.normalized.frozen?

      artifact = JSON.parse(first.artifact_bytes, decimal_class: BigDecimal)
      assert_equal %w[fixture_version observed_at request response], artifact.keys
      assert_equal 1, artifact.fetch("fixture_version")
      assert_equal fixture.fetch("observed_at"), artifact.fetch("observed_at")
      assert_equal fixture.fetch("request"), artifact.fetch("request")
      refute artifact.fetch("response").key?("message")

      replayed = Integrations::Cj::Normalizer.new.call(operation:,
        body: JSON.generate(artifact.fetch("response")), request: artifact.fetch("request"),
        observed_at: artifact.fetch("observed_at"))
      assert_equal first.normalized.value, replayed.value
      assert_equal first.normalized.request, replayed.request
    end
  end

  test "preserves high precision decimal measurements through canonical artifact replay" do
    fixture = fixture_for(:product)
    exact = BigDecimal("123456789.123456789")
    raw_body = JSON.generate(fixture.fetch("response")).sub(
      '"variantWeight":250.5',
      '"variantWeight":123456789.123456789'
    )

    result = validator.call(operation: :product, request: fixture.fetch("request"), raw_body:,
      observed_at: fixture.fetch("observed_at"))

    assert_equal exact, result.normalized.value.variants.first.weight.value
    assert_includes result.artifact_bytes, '"variantWeight":123456789.123456789'
    refute_includes result.artifact_bytes, '"variantWeight":"123456789.123456789"'

    artifact = JSON.parse(result.artifact_bytes, decimal_class: BigDecimal)
    replayed = Integrations::Cj::Normalizer.new.call(operation: :product,
      body: JSON.generate(artifact.fetch("response")), request: artifact.fetch("request"),
      observed_at: artifact.fetch("observed_at"))
    assert_equal exact, replayed.value.variants.first.weight.value
    assert_equal result.normalized.value, replayed.value
  end

  test "reads every captured operation as the identical immutable result" do
    %i[product inventory freight].each do |operation|
      captured = result_for(operation)
      input = captured.artifact_bytes.dup
      snapshot = input.dup

      replayed = validator.read(operation:, artifact_bytes: input)

      assert_equal captured, replayed
      assert_equal snapshot, input
      refute input.frozen?
      assert replayed.frozen?
      assert replayed.artifact_bytes.frozen?
      assert replayed.artifact_sha256.frozen?
      assert replayed.normalized.frozen?
      assert replayed.normalized.request.frozen?
      assert_raises(FrozenError) { replayed.artifact_bytes << "changed" }
      assert_raises(FrozenError) { replayed.normalized.request.values.first.replace("changed") }
      input.replace("changed")
      assert_equal captured, replayed
    end
  end

  test "reads reordered whitespace padded UTF-8 bytes with the same canonical bytes and hash" do
    captured = result_for(:product)
    envelope = JSON.parse(captured.artifact_bytes)
    envelope["response"] = envelope.fetch("response").to_a.reverse.to_h
    bytes = " \n#{JSON.pretty_generate(envelope.to_a.reverse.to_h)}\t ".b
    snapshot = bytes.dup

    replayed = validator.read(operation: :product, artifact_bytes: bytes)

    assert_equal captured, replayed
    assert_equal snapshot, bytes
    assert_equal Encoding::ASCII_8BIT, bytes.encoding
    assert_equal Encoding::UTF_8, replayed.artifact_bytes.encoding
  end

  test "reads exact decimals without floating point or quoted number conversion" do
    captured = result_for(:product)
    bytes = captured.artifact_bytes.sub('"variantWeight":250.5', '"variantWeight":123456789.123456789')

    replayed = validator.read(operation: :product, artifact_bytes: bytes)

    assert_equal BigDecimal("123456789.123456789"), replayed.normalized.value.variants.first.weight.value
    assert_includes replayed.artifact_bytes, '"variantWeight":123456789.123456789'
    assert_equal replayed, validator.read(operation: :product, artifact_bytes: replayed.artifact_bytes)
  end

  test "reads at most one MiB while preserving the provider response size limit" do
    captured = result_for(:product)
    limit = 1_048_576
    padded = captured.artifact_bytes.ljust(limit)
    assert_equal captured, validator.read(operation: :product, artifact_bytes: padded)
    assert_sanitized_error { validator.read(operation: :product, artifact_bytes: padded + " ") }

    envelope = JSON.parse(captured.artifact_bytes)
    envelope.fetch("response")["message"] = "x" * Integrations::Cj::Normalizer::MAX_BODY_BYTES
    assert_sanitized_error { validator.read(operation: :product, artifact_bytes: JSON.generate(envelope)) }
  end

  test "rejects invalid read operations and accepts bytes rather than IO paths or objects" do
    captured = result_for(:product)
    [ "product", :unknown, nil, true ].each do |operation|
      assert_error(:invalid_input) { validator.read(operation:, artifact_bytes: captured.artifact_bytes) }
    end
    [ nil, {}, [], StringIO.new(captured.artifact_bytes), Pathname.new("product.json"),
      "product.json", "file:///product.json", "https://example.invalid/product.json" ].each do |artifact_bytes|
      assert_sanitized_error { validator.read(operation: :product, artifact_bytes:) }
    end
  end

  test "requires an exact v1 artifact envelope" do
    envelope = JSON.parse(result_for(:product).artifact_bytes)
    variants = [ [], nil, true, {}, envelope.merge("operation" => "product"),
      envelope.merge("extra" => "SYNTHETIC-SECRET") ]
    envelope.each_key { |key| variants << envelope.except(key) }
    [ nil, true, "1", 1.0, 0, 2, -1 ].each do |version|
      variants << envelope.merge("fixture_version" => version)
    end
    variants.each do |value|
      assert_sanitized_error { validator.read(operation: :product, artifact_bytes: JSON.generate(value)) }
    end
  end

  test "revalidates request identity and canonical observation time on read" do
    envelope = JSON.parse(result_for(:product).artifact_bytes)
    [ {}, { "product_id" => "../secret" }, { "product_id" => "x" * 201 },
      { "product_id" => "00001234", "extra" => true } ].each do |request|
      bytes = JSON.generate(envelope.merge("request" => request))
      assert_sanitized_error(code: :invalid_input) { validator.read(operation: :product, artifact_bytes: bytes) }
    end
    [ nil, "2026-09-20", "2026-09-20T00:00:00+00:00", "2026-09-20T00:00:00.100Z",
      "2026-02-30T00:00:00Z", "2026-09-20T00:00:00Z\n" ].each do |observed_at|
      bytes = JSON.generate(envelope.merge("observed_at" => observed_at))
      assert_sanitized_error(code: :invalid_input) { validator.read(operation: :product, artifact_bytes: bytes) }
    end
    bytes = JSON.generate(envelope.merge("request" => { "product_id" => "different" }))
    assert_sanitized_error { validator.read(operation: :product, artifact_bytes: bytes) }
    assert_sanitized_error(code: :invalid_input) do
      validator.read(operation: :inventory, artifact_bytes: JSON.generate(envelope))
    end
  end

  test "rejects duplicate keys at every envelope boundary including escaped equivalent keys" do
    captured = result_for(:product).artifact_bytes
    [ captured.sub('"fixture_version":1', '"fixture_version":1,"fixture_version":1'),
      captured.sub('"fixture_version":1', '"fixture_version":1,"fixture_versi\u006fn":1'),
      captured.sub('"product_id":"00001234"', '"product_id":"00001234","product_id":"00001234"'),
      captured.sub('"code":200', '"code":200,"code":200'),
      captured.sub('"vid":"00005678"', '"vid":"00005678","vid":"00005678"') ].each do |bytes|
      refute_equal captured, bytes
      assert_sanitized_error { validator.read(operation: :product, artifact_bytes: bytes) }
    end
  end

  test "rejects malformed invalid UTF-8 excessive nesting and all out of bound numbers on read" do
    captured = result_for(:product).artifact_bytes
    invalid = [ "", "{", captured + "{}", captured.b + "\xFF".b,
      captured.encode(Encoding::UTF_16LE), "[" * 30 + "]" * 30 ]
    %w[NaN Infinity -Infinity 1e400 -1e400 10000000000 -10000000000 1e-1000000 -1e-1000000].each do |number|
      invalid << captured.sub('"variantWeight":250.5', "\"variantWeight\":#{number}")
      invalid << captured.sub('"code":200', "\"message\":#{number},\"code\":200")
    end
    invalid.each do |bytes|
      assert_sanitized_error { validator.read(operation: :product, artifact_bytes: bytes) }
    end
  end

  test "reapplies provider allowlists forbidden keys active content and URL safety on read" do
    envelope = JSON.parse(result_for(:product).artifact_bytes)
    mutations = [
      ->(response) { response["newProviderField"] = "SYNTHETIC-SECRET" },
      ->(response) { response.fetch("data").fetch("variants").first["ACCESS_TOKEN"] = "SYNTHETIC-SECRET" },
      ->(response) { response.fetch("data")["description"] = "<script>SYNTHETIC-SECRET</script>" },
      ->(response) { response.fetch("data")["pid"] = "different" }
    ]
    mutations.each do |mutation|
      copy = envelope.deep_dup
      mutation.call(copy.fetch("response"))
      assert_sanitized_error { validator.read(operation: :product, artifact_bytes: JSON.generate(copy)) }
    end
    envelope.fetch("response").fetch("data")["productImageSet"] = [ "javascript:SYNTHETIC-SECRET" ]
    assert_sanitized_error(code: :unsafe_url) do
      validator.read(operation: :product, artifact_bytes: JSON.generate(envelope))
    end
  end

  test "read results redact direct and nested serialization logs and dependency causes" do
    captured = result_for(:product)
    bytes = captured.artifact_bytes.sub('"productNameEn":"', '"productNameEn":"SYNTHETIC-SECRET ')
    assert_includes bytes, "SYNTHETIC-SECRET"
    result = validator.read(operation: :product, artifact_bytes: bytes)
    [ result, { "nested" => [ result ] } ].each do |value|
      [ value.inspect, value.to_s, value.as_json.inspect, value.to_json, JSON.generate(value) ].each do |output|
        refute_includes output, "SYNTHETIC-SECRET"
      end
      assert_raises(TypeError) { YAML.dump(value) }
      assert_raises(TypeError) { Marshal.dump(value) }
    end
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    logger.info(result)
    logger.info("captured=#{result}")
    logger.info({ "nested" => [ result ] })
    refute_includes log.string, "SYNTHETIC-SECRET"

    [ RuntimeError.new("SYNTHETIC-SECRET"), Integrations::Cj::Error.new(:authentication_failed) ].each do |failure|
      normalizer = Object.new
      normalizer.define_singleton_method(:call) do |**|
        begin
          raise "SYNTHETIC-SECRET"
        rescue RuntimeError
          raise failure
        end
      end
      code = failure.is_a?(Integrations::Cj::Error) ? :authentication_failed : :malformed_response
      assert_sanitized_error(code:) do
        Integrations::Cj::RecordArtifactValidator.new(normalizer:).read(operation: :product, artifact_bytes: bytes)
      end
    end
  end

  test "rejects positive negative and nonfinite numeric forms including discarded diagnostics" do
    fixture = fixture_for(:product)
    base = JSON.generate(fixture.fetch("response"))
    bodies = [
      base.sub('"variantWeight":250.5', '"variantWeight":1e400'),
      base.sub('"variantWeight":250.5', '"variantWeight":-1e400'),
      base.sub('"message":"Synthetic success"', '"message":1e400'),
      base.sub('"message":"Synthetic success"', '"message":-1e400'),
      base.sub('"message":"Synthetic success"', '"message":NaN'),
      base.sub('"message":"Synthetic success"', '"message":Infinity'),
      base.sub('"message":"Synthetic success"', '"message":-Infinity')
    ]

    bodies.each do |raw_body|
      assert_sanitized_error do
        validator.call(operation: :product, request: fixture.fetch("request"), raw_body:,
          observed_at: fixture.fetch("observed_at"))
      end
    end
  end

  test "canonicalizes key order without mutating caller inputs" do
    fixture = fixture_for(:product)
    request = fixture.fetch("request")
    body = fixture.fetch("response")
    reordered = body.to_a.reverse.to_h
    request_snapshot = Marshal.dump(request)
    body_snapshot = Marshal.dump(reordered)

    ordered = validator.call(operation: :product, request:, raw_body: JSON.generate(body), observed_at: fixture.fetch("observed_at"))
    reversed = validator.call(operation: :product, request:, raw_body: JSON.generate(reordered), observed_at: fixture.fetch("observed_at"))

    assert_equal ordered.artifact_bytes, reversed.artifact_bytes
    assert_equal request_snapshot, Marshal.dump(request)
    assert_equal body_snapshot, Marshal.dump(reordered)
    assert_raises(FrozenError) { reversed.artifact_bytes << "changed" }
    assert_raises(FrozenError) { reversed.normalized.request["product_id"] << "changed" }
  end

  test "accepts valid UTF-8 response bytes without trusting their encoding label" do
    fixture = fixture_for(:product)
    raw_body = JSON.generate(fixture.fetch("response")).b

    result = validator.call(operation: :product, request: fixture.fetch("request"), raw_body:,
      observed_at: fixture.fetch("observed_at"))

    assert_equal "00001234", result.normalized.value.external_id
    assert_equal Encoding::UTF_8, result.artifact_bytes.encoding
  end

  test "rejects invalid operations requests and observation timestamps" do
    fixture = fixture_for(:product)
    raw_body = JSON.generate(fixture.fetch("response"))
    valid = { operation: :product, request: fixture.fetch("request"), raw_body:, observed_at: fixture.fetch("observed_at") }

    [ "product", :unknown, nil, true ].each do |operation|
      assert_error(:invalid_input) { validator.call(**valid.merge(operation:)) }
    end
    [ nil, {}, { product_id: "00001234" }, { "product_id" => "" }, { "product_id" => "../secret" },
      { "product_id" => "00001234", "extra" => true } ].each do |request|
      assert_error(:invalid_input) { validator.call(**valid.merge(request:)) }
    end
    [ nil, Time.utc(2026), "", "2026-09-20", "2026-09-20T00:00:00+00:00", "2026-09-20T00:00:00.100Z",
      "2026-09-20T00:00:00Z\n" ].each do |observed_at|
      assert_error(:invalid_input) { validator.call(**valid.merge(observed_at:)) }
    end
  end

  test "enforces exact bounded inventory and freight request contracts" do
    inventory = fixture_for(:inventory)
    inventory_body = JSON.generate(inventory.fetch("response"))
    [ { "variant_id" => 56 }, { "variant_id" => "x" * 201 }, { "variant_id" => "id\nheader" } ].each do |request|
      assert_error(:invalid_input) do
        validator.call(operation: :inventory, request:, raw_body: inventory_body,
          observed_at: inventory.fetch("observed_at"))
      end
    end

    freight = fixture_for(:freight)
    freight_body = JSON.generate(freight.fetch("response"))
    invalid_requests = [
      freight.fetch("request").merge("destination_country" => "us"),
      freight.fetch("request").merge("items" => []),
      freight.fetch("request").merge("items" => [ { "variant_id" => "00005678", "quantity" => 0 } ]),
      freight.fetch("request").merge("items" => [ { "variant_id" => "00005678", "quantity" => 1, "extra" => true } ]),
      freight.fetch("request").merge("items" => Array.new(2) { { "variant_id" => "00005678", "quantity" => 1 } }),
      freight.fetch("request").merge("extra" => true)
    ]
    invalid_requests.each do |request|
      assert_error(:invalid_input) do
        validator.call(operation: :freight, request:, raw_body: freight_body,
          observed_at: freight.fetch("observed_at"))
      end
    end
  end

  test "rejects forbidden and unknown keys at every depth and case variation" do
    fixture = fixture_for(:product)
    base = fixture.fetch("response")
    forbidden_keys = %w[accessToken ACCESS_TOKEN refresh-token openId authorization sign signature apiKey email phone recipientName address zip token secret password]
    forbidden_keys.each do |key|
      body = base.deep_dup
      body.fetch("data").fetch("variants").first[key] = "SYNTHETIC-SECRET"
      assert_sanitized_error { validate_product(body) }
    end

    [ [ base.merge("newProviderField" => "value"), :root ],
      [ base.deep_dup.tap { |body| body.fetch("data")["newField"] = "value" }, :product ],
      [ base.deep_dup.tap { |body| body.fetch("data").fetch("variants").first["newField"] = "value" }, :variant ] ].each do |body, _location|
      assert_sanitized_error { validate_product(body) }
    end
  end

  test "rejects malformed duplicate non UTF-8 oversized deep and nonfinite responses" do
    fixture = fixture_for(:product)
    request = fixture.fetch("request")
    observed_at = fixture.fetch("observed_at")
    invalid_bodies = [
      "{",
      "{\"code\":200,\"code\":201,\"result\":true,\"data\":{}}",
      "{\"code\":200,\"result\":true,\"data\":{\"pid\":\"00001234\",\"pid\":\"duplicate\"}}",
      "{\"code\":200,\"result\":true,\"data\":NaN}",
      "[" * 30 + "]" * 30,
      "x" * (Integrations::Cj::Normalizer::MAX_BODY_BYTES + 1),
      "{\"code\":200}".b.force_encoding(Encoding::UTF_16LE),
      "{\"code\":200,\"result\":true,\"data\":\"\xFF\"}".b.force_encoding(Encoding::UTF_8)
    ]
    invalid_bodies.each do |raw_body|
      assert_sanitized_error do
        validator.call(operation: :product, request:, raw_body:, observed_at:)
      end
    end
  end

  test "rejects provider errors unsafe media identity mismatches and active content" do
    fixture = fixture_for(:product)
    provider_error = { "code" => 1600001, "result" => false, "message" => "SYNTHETIC-SECRET", "data" => nil }
    assert_sanitized_error(code: :authentication_failed) { validate_product(provider_error) }

    unsafe_media = fixture.fetch("response").deep_dup
    unsafe_media.fetch("data")["productImageSet"] = [ "https://127.0.0.1/SYNTHETIC-SECRET" ]
    assert_sanitized_error(code: :unsafe_url) { validate_product(unsafe_media) }

    mismatch = fixture.fetch("response").deep_dup
    mismatch.fetch("data")["pid"] = "different"
    assert_sanitized_error { validate_product(mismatch) }

    active = fixture.fetch("response").deep_dup
    active.fetch("data")["description"] = "<p>Safe</p><script>SYNTHETIC-SECRET</script>"
    assert_sanitized_error { validate_product(active) }

    attributed = fixture.fetch("response").deep_dup
    attributed.fetch("data")["description"] = '<p class="provider-style">Safe</p>'
    assert_sanitized_error { validate_product(attributed) }
  end

  test "does not expose artifact bytes through inspect JSON errors or logs" do
    result = result_for(:product)
    refute_includes result.inspect, result.artifact_bytes
    refute_includes result.as_json.inspect, result.artifact_bytes
    refute_includes result.to_json, result.artifact_bytes
    assert_equal({ "operation" => "product", "fixture_version" => 1,
      "artifact_sha256" => result.artifact_sha256 }, result.as_json)

    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    error = assert_raises(Integrations::Cj::Error) do
      validator.call(operation: :product, request: { "product_id" => "00001234" },
        raw_body: '{"SYNTHETIC-SECRET":', observed_at: "2026-09-20T00:00:00Z")
    end
    refute_includes error.full_message, "SYNTHETIC-SECRET"
    assert_nil error.cause
    assert_empty log.string
  ensure
    Rails.logger = previous_logger
  end

  test "redacts string interpolation and refuses direct or nested YAML and Marshal serialization" do
    fixture = fixture_for(:product)
    sentinel = "SENTINEL-SUPPLIER-PAYLOAD"
    body = fixture.fetch("response")
    body.fetch("data")["description"] = sentinel
    result = validator.call(operation: :product, request: fixture.fetch("request"),
      raw_body: JSON.generate(body), observed_at: fixture.fetch("observed_at"))

    assert_includes result.artifact_bytes, sentinel
    assert_equal sentinel, result.normalized.value.description
    refute_includes result.to_s, sentinel
    refute_includes "captured=#{result}", sentinel

    [ result, { "nested" => [ result ] } ].each do |value|
      assert_raises(TypeError) { YAML.dump(value) }
      assert_raises(TypeError) { Marshal.dump(value) }
    end

    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.info("captured=#{result}")
    logger.info(result)
    logger.info({ "nested" => [ result ] })
    refute_includes output.string, sentinel
    refute_includes output.string, result.artifact_bytes
  end

  test "performs no network database retry sleep or filesystem write" do
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*event| queries << event }
    original_http = Net::HTTP.method(:start)
    original_sleep = Kernel.instance_method(:sleep)
    original_write = File.method(:write)
    original_binwrite = File.method(:binwrite)
    Net::HTTP.define_singleton_method(:start) { |*| raise "unexpected network" }
    Kernel.define_method(:sleep) { |*| raise "unexpected sleep" }
    File.define_singleton_method(:write) { |*| raise "unexpected write" }
    File.define_singleton_method(:binwrite) { |*| raise "unexpected write" }

    assert result_for(:product)
    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Net::HTTP.define_singleton_method(:start, original_http) if original_http
    Kernel.define_method(:sleep, original_sleep) if original_sleep
    File.define_singleton_method(:write, original_write) if original_write
    File.define_singleton_method(:binwrite, original_binwrite) if original_binwrite
  end

  private
    def validator
      @validator ||= Integrations::Cj::RecordArtifactValidator.new
    end

    def fixture_for(operation)
      JSON.parse(FIXTURES.join("#{operation}.json").read)
    end

    def result_for(operation)
      fixture = fixture_for(operation)
      validator.call(operation:, request: fixture.fetch("request"),
        raw_body: JSON.generate(fixture.fetch("response")), observed_at: fixture.fetch("observed_at"))
    end

    def validate_product(body)
      fixture = fixture_for(:product)
      validator.call(operation: :product, request: fixture.fetch("request"), raw_body: JSON.generate(body),
        observed_at: fixture.fetch("observed_at"))
    end

    def assert_sanitized_error(code: :malformed_response, &block)
      error = assert_error(code, &block)
      refute_includes error.full_message, "SYNTHETIC-SECRET"
      assert_nil error.cause
    end

    def assert_error(code, &block)
      error = assert_raises(Integrations::Cj::Error, &block)
      assert_equal code, error.code
      assert_equal "CJ adapter: #{code}", error.message
      error
    end
end
