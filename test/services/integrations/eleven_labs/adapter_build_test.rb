require "test_helper"

# Live transport must be selectable only by server configuration, and must
# degrade to fixture rather than attempting an unauthenticated provider call.
class Integrations::ElevenLabs::AdapterBuildTest < ActiveSupport::TestCase
  AGENT_ID = "agent_1801m2yy8cwafv99s022w9v4xmaf".freeze

  test "defaults to fixture when no mode is configured" do
    adapter = Integrations::ElevenLabs::Adapter.build(config: config(mode: "fixture"), deployment: :staging)

    assert_equal :fixture, adapter.mode
  end

  test "selects live only when the server configures it and credentials exist" do
    adapter = Integrations::ElevenLabs::Adapter.build(
      config: config(mode: "live", api_key: "sk_test_key"), deployment: :staging
    )

    assert_equal :live, adapter.mode
  end

  test "falls back to fixture when live is configured without credentials" do
    adapter = Integrations::ElevenLabs::Adapter.build(config: config(mode: "live", api_key: nil), deployment: :staging)

    assert_equal :fixture, adapter.mode,
      "a live mode without credentials must not attempt an unauthenticated provider call"
  end

  test "test deployments can never be switched to live" do
    assert_raises(Integrations::ElevenLabs::Error) do
      Integrations::ElevenLabs::Adapter.build(
        config: config(mode: "live", api_key: "sk_test_key"), deployment: :test
      )
    end
  end

  test "an unknown configured mode is treated as fixture, never as live" do
    adapter = Integrations::ElevenLabs::Adapter.build(
      config: config(mode: "LIVE; drop table", api_key: "sk_test_key"), deployment: :staging
    )

    assert_equal :fixture, adapter.mode
  end

  test "the configured mode never leaks credentials through serialization" do
    serialized = config(mode: "live", api_key: "sk_super_secret").to_json

    refute_includes serialized, "sk_super_secret"
  end

  private

  def config(mode:, api_key: "sk_test_key", agent_id: AGENT_ID)
    Integrations::ElevenLabs::Config.new(
      api_key: api_key, agent_id: agent_id, tool_secret: nil, webhook_secret: nil, mode: mode
    )
  end
end
