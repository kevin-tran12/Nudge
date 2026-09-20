require "test_helper"

class CjModePolicyTest < ActiveSupport::TestCase
  test "fixture is the default in tests development and staging" do
    [ :test, :development, :staging, "test" ].each do |deployment|
      policy = Integrations::Cj::ModePolicy.new(deployment: deployment)
      assert_equal :fixture, policy.mode
      assert_equal 0, policy.ceiling
      assert policy.frozen?
    end
  end

  test "verify and record require matching explicit server capabilities" do
    policy_class = Integrations::Cj::ModePolicy
    { verify: [ policy_class::VERIFY_CAPABILITY, 500 ], record: [ policy_class::RECORD_CAPABILITY, 2_500 ] }.each do |mode, (capability, ceiling)|
      [ :development, :staging ].each do |deployment|
        policy = policy_class.new(deployment: deployment, mode: mode.to_s, capability: capability)
        assert_equal mode, policy.mode
        assert_equal ceiling, policy.ceiling
      end
      [ nil, true, mode, mode.to_s, {}, Object.new ].each do |untrusted|
        assert_denied { policy_class.new(deployment: :development, mode: mode, capability: untrusted) }
      end
    end
    assert_denied do
      policy_class.new(deployment: :development, mode: :verify, capability: policy_class::RECORD_CAPABILITY)
    end
  end

  test "all mode and deployment combinations fail closed outside the approved matrix" do
    policy_class = Integrations::Cj::ModePolicy
    capabilities = { fixture: nil, verify: policy_class::VERIFY_CAPABILITY,
      record: policy_class::RECORD_CAPABILITY, live: policy_class::LIVE_CAPABILITY }
    allowed = { test: [ :fixture ], development: [ :fixture, :verify, :record ],
      staging: [ :fixture, :verify, :record ], production: [ :live ] }
    allowed.each do |deployment, modes|
      capabilities.each do |mode, capability|
        if modes.include?(mode)
          assert_equal mode, policy_class.new(deployment: deployment, mode: mode, capability: capability).mode
        else
          assert_denied { policy_class.new(deployment: deployment, mode: mode, capability: capability) }
        end
      end
    end
    assert_denied { policy_class.new(deployment: :production, mode: :live) }
    assert_nil policy_class.new(deployment: :production, mode: :live, capability: policy_class::LIVE_CAPABILITY).ceiling
    # Policy evaluation cannot enable the existing fixture-only adapter.
    assert_denied { Integrations::Cj::Adapter.new(mode: :live) }
  end

  test "invalid modes and deployment inputs are rejected without coercion or input disclosure" do
    [ nil, true, 1, {}, [], Object.new, :sandbox, "LIVE", "live\n", "Bearer synthetic-secret" ].each do |input|
      assert_denied { Integrations::Cj::ModePolicy.new(deployment: :development, mode: input) }
      assert_denied { Integrations::Cj::ModePolicy.new(deployment: input) }
    end
  end

  private

  def assert_denied(&block)
    error = assert_raises(Integrations::Cj::Error, &block)
    assert_equal :unsupported_mode, error.code
    assert_equal :never, error.retry_strategy
    assert_equal "CJ adapter: unsupported_mode", error.message
  end
end
