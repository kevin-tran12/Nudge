require "test_helper"

class CjAdapterTransportTest < ActiveSupport::TestCase
  ModePolicy = Integrations::Cj::ModePolicy
  Governor = Integrations::Cj::Governor
  CjError = Integrations::Cj::Error

  FakeToken = Struct.new(:value)
  FakeAuthResult = Struct.new(:token)

  class FakeAuthentication
    def initialize(token_value: "synthetic-token", error: nil)
      @token_value = token_value
      @error = error
      @calls = 0
    end

    attr_reader :calls

    def fetch
      @calls += 1
      raise @error if @error

      FakeAuthResult.new(FakeToken.new(@token_value))
    end
  end

  class FakeTransport
    def initialize(&behavior)
      @behavior = behavior
      @calls = []
    end

    attr_reader :calls

    def call(operation:, token:, request:)
      @calls << { operation: operation, token: token, request: request }
      @behavior.call(@calls.size)
    end

    def authenticate(credential:)
      flunk "authenticate should not be reached by these fakes"
    end
  end

  class PoisonedTransport
    def call(**)
      raise "transport must not be invoked"
    end

    def authenticate(**)
      raise "transport must not be invoked"
    end
  end

  PRODUCT_BODY = %({"code":200,"result":true,"data":{"pid":"00001234","productNameEn":"Widget","variants":[]}}).freeze

  test "a non-fixture mode is refused without the matching explicit capability object" do
    [ :verify, :record ].each do |mode|
      error = assert_raises(CjError) { Integrations::Cj::Adapter.new(mode: mode, deployment: :development) }
      assert_equal :unsupported_mode, error.code
    end
    error = assert_raises(CjError) { Integrations::Cj::Adapter.new(mode: :live, deployment: :production) }
    assert_equal :unsupported_mode, error.code
  end

  test "the transport is never constructed or invoked in fixture mode even if one is supplied" do
    adapter = Integrations::Cj::Adapter.new(transport: PoisonedTransport.new, governor: :unused, authentication: :unused)
    result = adapter.product(product_id: "00001234")
    assert_equal :fixture, adapter.mode
    assert_instance_of Integrations::Cj::Contracts::Product, result.value
  end

  test "points-budget exhaustion fails closed before the transport is ever invoked" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 10) # catalog partition = 6, product costs 50
    transport = FakeTransport.new { flunk "governor exhaustion must prevent a transport call" }
    adapter = build_adapter(policy: policy, governor: governor, transport: transport)

    error = assert_raises(CjError) { adapter.product(product_id: "00001234") }

    assert_equal :quota_exhausted, error.code
    assert_empty transport.calls
  end

  test "rate-governor refusal fails closed before the transport is invoked, then recovers" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    now = 100.0
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { now })
    governor.admit!(purpose: :catalog, points: 1)
    transport = FakeTransport.new { PRODUCT_BODY }
    waits = []
    adapter = build_adapter(policy: policy, governor: governor, transport: transport,
      waiter: ->(seconds) { waits << seconds; now += seconds })

    result = adapter.product(product_id: "00001234")

    assert_equal 1, transport.calls.size
    assert_instance_of Integrations::Cj::Contracts::Product, result.value
    refute_empty waits
  end

  test "a transient failure retries a bounded number of times before succeeding" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    t = 0
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { t += 2 })
    transport = FakeTransport.new { |call_count| call_count < 3 ? raise(CjError.new(:unavailable)) : PRODUCT_BODY }
    waits = []
    adapter = build_adapter(policy: policy, governor: governor, transport: transport,
      waiter: ->(seconds) { waits << seconds })

    result = adapter.product(product_id: "00001234")

    assert_equal 3, transport.calls.size
    assert_equal [ 1.0, 1.0 ], waits
    assert_instance_of Integrations::Cj::Contracts::Product, result.value
  end

  test "throttled responses back off using the provider-reported delay and remain bounded" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    t = 0
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { t += 2 })
    transport = FakeTransport.new { |call_count| call_count < 2 ? raise(CjError.new(:throttled)) : PRODUCT_BODY }
    waits = []
    adapter = build_adapter(policy: policy, governor: governor, transport: transport,
      waiter: ->(seconds) { waits << seconds })

    adapter.product(product_id: "00001234")

    assert_equal 2, transport.calls.size
    assert_equal [ 1.0 ], waits
  end

  test "a malformed body is terminal and never retried" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { 0 })
    transport = FakeTransport.new { raise CjError.new(:malformed_response) }
    waiter_calls = 0
    adapter = build_adapter(policy: policy, governor: governor, transport: transport,
      waiter: ->(_seconds) { waiter_calls += 1 })

    error = assert_raises(CjError) { adapter.product(product_id: "00001234") }

    assert_equal :malformed_response, error.code
    assert_equal 1, transport.calls.size
    assert_equal 0, waiter_calls
  end

  test "an oversized body is classified as malformed and never retried" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { 0 })
    transport = FakeTransport.new { raise CjError.new(:malformed_response) } # Transport itself enforces the byte cap
    adapter = build_adapter(policy: policy, governor: governor, transport: transport)

    assert_raises(CjError) { adapter.product(product_id: "00001234") }
    assert_equal 1, transport.calls.size
  end

  test "auth expiry pauses without a retry storm and never reaches the transport" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { 0 })
    transport = FakeTransport.new { flunk "transport must not be reached while authentication is failing" }
    authentication = FakeAuthentication.new(error: CjError.new(:authentication_failed))
    adapter = build_adapter(policy: policy, governor: governor, transport: transport, authentication: authentication)

    error = assert_raises(CjError) { adapter.product(product_id: "00001234") }

    assert_equal :authentication_failed, error.code
    assert_equal 1, authentication.calls
    assert_empty transport.calls
  end

  test "an unbounded transient failure never loops forever" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    t = 0
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { t += 2 })
    transport = FakeTransport.new { raise CjError.new(:unavailable) }
    adapter = build_adapter(policy: policy, governor: governor, transport: transport, waiter: ->(_s) { })

    error = assert_raises(CjError) { adapter.product(product_id: "00001234") }

    assert_equal :unavailable, error.code
    assert_equal Integrations::Cj::Adapter::MAX_ATTEMPTS, transport.calls.size
  end

  test "a live response flows through the normalizer and no raw provider hash escapes" do
    policy = ModePolicy.new(deployment: :development, mode: :verify, capability: ModePolicy::VERIFY_CAPABILITY)
    governor = Governor.new(policy: policy, points_limit: 500, clock: -> { 0 })
    transport = FakeTransport.new { PRODUCT_BODY }
    adapter = build_adapter(policy: policy, governor: governor, transport: transport)

    result = adapter.product(product_id: "00001234")

    assert_instance_of Integrations::Cj::Contracts::Result, result
    assert_instance_of Integrations::Cj::Contracts::Product, result.value
    refute_kind_of Hash, result.value
    assert result.frozen?
    assert_equal "00001234", transport.calls.first.fetch(:request).fetch("product_id")
    assert_equal "synthetic-token", transport.calls.first.fetch(:token)
  end

  private
    def build_adapter(policy:, governor:, transport:, authentication: nil, waiter: ->(_seconds) { })
      Integrations::Cj::Adapter.new(mode: policy.mode, deployment: :development, capability: capability_for(policy),
        config: Integrations::Cj::Config.new(api_key: "synthetic-key"), governor: governor, transport: transport,
        authentication: authentication || FakeAuthentication.new, waiter: waiter)
    end

    def capability_for(policy)
      case policy.mode
      when :verify then ModePolicy::VERIFY_CAPABILITY
      when :record then ModePolicy::RECORD_CAPABILITY
      when :live then ModePolicy::LIVE_CAPABILITY
      end
    end
end
