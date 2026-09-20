require "test_helper"
require "digest"
require "json"
require "net/http"
require "stringio"

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

      artifact = JSON.parse(first.artifact_bytes)
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
