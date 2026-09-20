require "test_helper"

# CAT-SYNC-01: the record-mode raw sink is the only seam through which the
# untouched provider bytes escape the adapter. It must fire in record mode and
# never in fixture, verify, or live mode.
class CjAdapterRawSinkTest < ActiveSupport::TestCase
  ModePolicy = Integrations::Cj::ModePolicy
  CjError = Integrations::Cj::Error

  PRODUCT_BODY =
    %({"code":200,"result":true,"requestId":"raw-1","data":{"pid":"00001234","productNameEn":"Widget","variants":[]}}).freeze

  FakeToken = Struct.new(:value)
  FakeAuthResult = Struct.new(:token)

  class FakeAuthentication
    def fetch
      FakeAuthResult.new(FakeToken.new("synthetic-token"))
    end
  end

  class FakeTransport
    def initialize(body)
      @body = body
    end

    def call(operation:, token:, request:)
      @body
    end

    def authenticate(credential:)
      raise "authenticate must not be reached"
    end
  end

  class RecordingSink
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(operation:, request:, body:, observed_at:)
      @calls << { operation:, request:, body:, observed_at: }
      nil
    end
  end

  test "record mode hands the untouched response bytes, request, and observed_at to the sink" do
    sink = RecordingSink.new
    adapter = build_adapter(mode: :record, capability: ModePolicy::RECORD_CAPABILITY, sink: sink)

    result = adapter.product(product_id: "00001234")

    assert_equal 1, sink.calls.size
    capture = sink.calls.sole
    assert_equal :product, capture.fetch(:operation)
    assert_equal({ "product_id" => "00001234" }, capture.fetch(:request))
    assert_equal PRODUCT_BODY, capture.fetch(:body)
    assert_equal "2026-09-20T00:00:00Z", capture.fetch(:observed_at)
    # The sink is additive: the normalized contract the caller receives is unchanged.
    assert_instance_of Integrations::Cj::Contracts::Product, result.value
    assert_equal "00001234", result.value.external_id
    assert_equal Time.utc(2026, 9, 20), result.provenance.observed_at
  end

  test "the observed_at handed to the sink is the same instant the normalizer records" do
    sink = RecordingSink.new
    adapter = build_adapter(mode: :record, capability: ModePolicy::RECORD_CAPABILITY, sink: sink)

    result = adapter.product(product_id: "00001234")

    assert_equal result.provenance.observed_at, Time.iso8601(sink.calls.sole.fetch(:observed_at))
  end

  test "verify and live modes never invoke the sink" do
    [ [ :verify, :development, ModePolicy::VERIFY_CAPABILITY ],
      [ :live, :production, ModePolicy::LIVE_CAPABILITY ] ].each do |mode, deployment, capability|
      sink = ->(**) { flunk "#{mode} mode must never invoke the raw sink" }
      adapter = build_adapter(mode:, deployment:, capability:, sink:)

      assert_instance_of Integrations::Cj::Contracts::Product, adapter.product(product_id: "00001234").value
    end
  end

  test "fixture mode never invokes the sink and never reaches a transport" do
    sink = ->(**) { flunk "fixture mode must never invoke the raw sink" }
    adapter = Integrations::Cj::Adapter.new(raw_sink: sink)

    assert_equal :fixture, adapter.mode
    assert_instance_of Integrations::Cj::Contracts::Product, adapter.product(product_id: "00001234").value
  end

  test "a raw sink that is not callable is refused at construction" do
    error = assert_raises(CjError) do
      Integrations::Cj::Adapter.new(raw_sink: :not_callable)
    end
    assert_equal :invalid_input, error.code
  end

  test "the default sink is a no-op so existing record callers keep working" do
    adapter = build_adapter(mode: :record, capability: ModePolicy::RECORD_CAPABILITY)

    assert_instance_of Integrations::Cj::Contracts::Product, adapter.product(product_id: "00001234").value
  end

  private
    def build_adapter(mode:, capability:, deployment: :development, sink: nil, body: PRODUCT_BODY)
      policy = ModePolicy.new(deployment:, mode:, capability:)
      governor = Integrations::Cj::Governor.new(policy:, points_limit: 500,
        clock: fake_monotonic_clock)
      options = { mode:, deployment:, capability:, config: Integrations::Cj::Config.new(api_key: "synthetic"),
        governor:, transport: FakeTransport.new(body), authentication: FakeAuthentication.new,
        clock: -> { Time.utc(2026, 9, 20) } }
      options[:raw_sink] = sink if sink
      Integrations::Cj::Adapter.new(**options)
    end

    def fake_monotonic_clock
      time = 0.0
      -> { time += 2.0 }
    end
end
