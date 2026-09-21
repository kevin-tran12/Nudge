require "test_helper"
require "net/http"

# Prodigi sandbox transport must be selectable only by server configuration.
# There is no live mode to select: ModePolicy knows only :fixture and
# :sandbox, so a real fulfillment-money order is unreachable by construction
# in this phase.
class Integrations::Prodigi::AdapterBuildTest < ActiveSupport::TestCase
  test "defaults to fixture when no mode is configured" do
    adapter = Integrations::Prodigi::Adapter.build(config: config(mode: "fixture"), deployment: :staging)
    assert_equal :fixture, adapter.mode
  end

  test "selects sandbox only when the server configures it and credentials exist" do
    adapter = Integrations::Prodigi::Adapter.build(
      config: config(mode: "sandbox", api_key: "synthetic-key"), deployment: :staging
    )
    assert_equal :sandbox, adapter.mode
  end

  test "sandbox configured without credentials stays fixture and never attempts an unauthenticated call" do
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "Prodigi fixture attempted HTTP" }

    adapter = Integrations::Prodigi::Adapter.build(
      config: config(mode: "sandbox", api_key: nil), deployment: :staging
    )

    assert_equal :fixture, adapter.mode,
      "sandbox configured without credentials must not attempt an unauthenticated provider call"
    assert_nothing_raised { adapter.product(sku: "GLOBAL-CFPM-16X24") }
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  test "an unknown configured mode is treated as fixture, never as sandbox" do
    [ "sandbox; drop table", "live", "SANDBOX", "true", "1", "" ].each do |value|
      adapter = Integrations::Prodigi::Adapter.build(
        config: config(mode: value, api_key: "synthetic-key"), deployment: :staging
      )
      assert_equal :fixture, adapter.mode, "mode #{value.inspect} must not select sandbox"
    end
  end

  test "there is no live mode to configure" do
    assert_equal [ :fixture, :sandbox ], Integrations::Prodigi::ModePolicy::MODES.to_a

    assert_raises(Integrations::Prodigi::Error) do
      Integrations::Prodigi::ModePolicy.new(
        deployment: :production, mode: :live, capability: Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY
      )
    end
  end

  test "test deployments can never be switched to sandbox" do
    assert_raises(Integrations::Prodigi::Error) do
      Integrations::Prodigi::Adapter.build(
        config: config(mode: "sandbox", api_key: "synthetic-key"), deployment: :test
      )
    end
  end

  test "an explicitly passed capability still selects sandbox even without a sandbox-configured Config" do
    adapter = Integrations::Prodigi::Adapter.build(
      capability: Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY,
      config: config(mode: "fixture"), deployment: :development
    )
    assert_equal :sandbox, adapter.mode
  end

  test "a caller-supplied non-sentinel capability cannot reach sandbox" do
    assert_raises(Integrations::Prodigi::Error) do
      Integrations::Prodigi::Adapter.build(
        capability: "sandbox", config: config(mode: "fixture"), deployment: :production
      )
    end
  end

  test "the configured mode never leaks credentials through serialization or errors" do
    secret = "synthetic-prodigi-super-secret"
    subject = config(mode: "sandbox", api_key: secret)

    refute_includes subject.inspect, secret
    refute_includes subject.to_s, secret
    refute_includes subject.as_json.to_s, secret
    refute_includes subject.to_json, secret

    error = assert_raises(Integrations::Prodigi::Error) do
      Integrations::Prodigi::Adapter.build(config: subject, deployment: :test)
    end
    refute_includes error.message, secret
    refute_includes error.inspect, secret
  end

  test "the config predicate requires both an explicit mode and credentials" do
    assert config(mode: "sandbox", api_key: "synthetic-key").sandbox?
    refute config(mode: "sandbox", api_key: nil).sandbox?
    refute config(mode: "fixture", api_key: "synthetic-key").sandbox?
  end

  private

  def config(mode:, api_key: "synthetic-key")
    Integrations::Prodigi::Config.new(api_key: api_key, mode: mode)
  end
end
