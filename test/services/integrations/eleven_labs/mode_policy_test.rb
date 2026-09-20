require "test_helper"

class ElevenLabsModePolicyTest < ActiveSupport::TestCase
  test "fixture is the only mode allowed in test and requires no capability" do
    policy = Integrations::ElevenLabs::ModePolicy.new(deployment: :test)
    assert_equal :fixture, policy.mode

    assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: :test, mode: :live) }
    assert_error(:unsupported_mode) do
      Integrations::ElevenLabs::ModePolicy.new(deployment: :test, mode: :live,
        capability: Integrations::ElevenLabs::ModePolicy::LIVE_CAPABILITY)
    end
  end

  test "development and staging allow fixture by default and live only with the capability marker" do
    [ :development, :staging ].each do |deployment|
      assert_equal :fixture, Integrations::ElevenLabs::ModePolicy.new(deployment: deployment).mode
      assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: deployment, mode: :live) }
      assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: deployment, mode: :live, capability: Object.new.freeze) }

      policy = Integrations::ElevenLabs::ModePolicy.new(deployment: deployment, mode: :live,
        capability: Integrations::ElevenLabs::ModePolicy::LIVE_CAPABILITY)
      assert_equal :live, policy.mode
    end
  end

  test "production requires live mode with the exact capability sentinel and rejects fixture" do
    assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: :production) }
    assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: :production, mode: :live) }

    policy = Integrations::ElevenLabs::ModePolicy.new(deployment: :production, mode: :live,
      capability: Integrations::ElevenLabs::ModePolicy::LIVE_CAPABILITY)
    assert_equal :live, policy.mode
  end

  test "unknown modes and deployments fail closed" do
    assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: :test, mode: :verify) }
    assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: :nowhere) }
    assert_error(:unsupported_mode) { Integrations::ElevenLabs::ModePolicy.new(deployment: :test, mode: nil) }
  end

  private

  def assert_error(code, &block)
    error = assert_raises(Integrations::ElevenLabs::Error, &block)
    assert_equal code, error.code
    error
  end
end
