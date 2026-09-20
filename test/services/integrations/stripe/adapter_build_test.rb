require "test_helper"
require "net/http"

# Stripe TEST-mode transport must be selectable only by server configuration,
# and must degrade to fixture rather than attempting an unauthenticated call.
# There is no live-money mode to select: ModePolicy knows only :fixture and
# :test_mode, so real-money transport is unreachable by construction.
class Integrations::Stripe::AdapterBuildTest < ActiveSupport::TestCase
  test "defaults to fixture when no mode is configured" do
    adapter = Integrations::Stripe::Adapter.build(config: config(mode: "fixture"), deployment: :staging)

    assert_equal :fixture, adapter.mode
  end

  test "selects test mode only when the server configures it and credentials exist" do
    adapter = Integrations::Stripe::Adapter.build(
      config: config(mode: "test_mode", secret_key: "sk_test_key"), deployment: :staging
    )

    assert_equal :test_mode, adapter.mode
  end

  test "falls back to fixture when test mode is configured without credentials and makes no call" do
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "Stripe fixture attempted HTTP" }

    adapter = Integrations::Stripe::Adapter.build(
      config: config(mode: "test_mode", secret_key: nil), deployment: :staging
    )

    assert_equal :fixture, adapter.mode,
      "a test mode without credentials must not attempt an unauthenticated provider call"

    session = adapter.create_checkout_session(
      line_items: [ { name: "Widget", amount: 1_500, quantity: 1 } ], currency: "usd", idempotency_key: "idem-key-1"
    )
    assert_match(/\Acs_test_fixture_/, session.id)
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  test "an unknown configured mode is treated as fixture, never as test mode" do
    [ "test_mode; drop table", "live", "TEST_MODE", "true", "1", "" ].each do |value|
      adapter = Integrations::Stripe::Adapter.build(
        config: config(mode: value, secret_key: "sk_test_key"), deployment: :staging
      )

      assert_equal :fixture, adapter.mode, "mode #{value.inspect} must not select test mode"
    end
  end

  test "there is no live mode to configure" do
    assert_equal [ :fixture, :test_mode ], Integrations::Stripe::ModePolicy::MODES.to_a

    assert_raises(Integrations::Stripe::Error) do
      Integrations::Stripe::ModePolicy.new(
        deployment: :production, mode: :live, capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY
      )
    end
  end

  test "test deployments can never be switched to test mode" do
    assert_raises(Integrations::Stripe::Error) do
      Integrations::Stripe::Adapter.build(
        config: config(mode: "test_mode", secret_key: "sk_test_key"), deployment: :test
      )
    end
  end

  test "an explicitly passed capability still selects test mode" do
    adapter = Integrations::Stripe::Adapter.build(
      capability: Integrations::Stripe::ModePolicy::TEST_MODE_CAPABILITY,
      config: config(mode: "fixture"), deployment: :development
    )

    assert_equal :test_mode, adapter.mode
  end

  test "a caller-supplied non-sentinel capability cannot reach test mode" do
    assert_raises(Integrations::Stripe::Error) do
      Integrations::Stripe::Adapter.build(
        capability: "test_mode", config: config(mode: "fixture"), deployment: :production
      )
    end
  end

  test "the configured mode never leaks credentials through serialization or errors" do
    secret = "sk_test_super_secret"
    subject = config(mode: "test_mode", secret_key: secret)

    refute_includes subject.inspect, secret
    refute_includes subject.to_s, secret
    refute_includes subject.as_json.to_s, secret
    refute_includes subject.to_json, secret

    error = assert_raises(Integrations::Stripe::Error) do
      Integrations::Stripe::Adapter.build(config: subject, deployment: :test)
    end
    refute_includes error.message, secret
    refute_includes error.inspect, secret
  end

  test "the config predicate requires both an explicit mode and credentials" do
    assert config(mode: "test_mode", secret_key: "sk_test_key").test_mode?
    refute config(mode: "test_mode", secret_key: nil).test_mode?
    refute config(mode: "fixture", secret_key: "sk_test_key").test_mode?
  end

  private

  def config(mode:, secret_key: "sk_test_key", webhook_secret: nil)
    Integrations::Stripe::Config.new(secret_key: secret_key, webhook_secret: webhook_secret, mode: mode)
  end
end
