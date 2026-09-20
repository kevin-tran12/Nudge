require "test_helper"

class StripeModePolicyTest < ActiveSupport::TestCase
  test "fixture is the only mode allowed in test and requires no capability" do
    policy = Integrations::Stripe::ModePolicy.new(deployment: :test)
    assert_equal :fixture, policy.mode

    assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: :test, mode: :test_mode) }
    assert_error(:unsupported_mode) do
      Integrations::Stripe::ModePolicy.new(deployment: :test, mode: :test_mode,
        capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY)
    end
  end

  test "development and staging allow fixture by default and test_mode only with the capability marker" do
    [ :development, :staging ].each do |deployment|
      assert_equal :fixture, Integrations::Stripe::ModePolicy.new(deployment: deployment).mode
      assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: deployment, mode: :test_mode) }
      assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: deployment, mode: :test_mode, capability: Object.new.freeze) }

      policy = Integrations::Stripe::ModePolicy.new(deployment: deployment, mode: :test_mode,
        capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY)
      assert_equal :test_mode, policy.mode
    end
  end

  test "production requires test_mode with the exact capability sentinel and rejects fixture" do
    assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: :production) }
    assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: :production, mode: :test_mode) }

    policy = Integrations::Stripe::ModePolicy.new(deployment: :production, mode: :test_mode,
      capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY)
    assert_equal :test_mode, policy.mode
  end

  test "there is no live mode and unknown modes or deployments fail closed" do
    assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: :test, mode: :live) }
    assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: :production, mode: :live, capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY) }
    assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: :nowhere) }
    assert_error(:unsupported_mode) { Integrations::Stripe::ModePolicy.new(deployment: :test, mode: nil) }
  end

  private

  def assert_error(code, &block)
    error = assert_raises(Integrations::Stripe::Error, &block)
    assert_equal code, error.code
    error
  end
end
