require "test_helper"
require "net/http"

class ElevenLabsAdapterTest < ActiveSupport::TestCase
  FROZEN_TIME = Time.utc(2026, 9, 20, 12, 0, 0)

  test "fixture mode is deterministic and makes zero network calls or database queries" do
    previous = ENV["ELEVENLABS_MODE"]
    ENV["ELEVENLABS_MODE"] = "live"
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*event| queries << event }
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*| raise "ElevenLabs fixture attempted HTTP" }

    adapter = adapter_with(agent_id: "agent-123")
    first = adapter.conversation_authorization
    second = adapter.conversation_authorization

    assert_equal :fixture, adapter.mode
    assert_equal first.conversation_token, second.conversation_token
    assert_equal "agent-123", first.agent_id
    assert_equal FROZEN_TIME + Integrations::ElevenLabs::Adapter::TOKEN_TTL, first.expires_at
    assert_empty queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Net::HTTP.define_singleton_method(:start, original) if original
    ENV["ELEVENLABS_MODE"] = previous
  end

  test "fixture mode never leaks the agent id as a mutable reference" do
    agent_id = +"agent-456"
    adapter_with(agent_id: agent_id).conversation_authorization
    refute agent_id.frozen?
  end

  test "missing agent id configuration fails closed without a network call" do
    adapter = Integrations::ElevenLabs::Adapter.new(
      mode_policy: Integrations::ElevenLabs::ModePolicy.new(deployment: :test),
      config: config_for(agent_id: nil), clock: -> { FROZEN_TIME }
    )
    assert_error(:missing_credentials) { adapter.conversation_authorization }
  end

  test "live mode is unreachable without the capability marker in every deployment" do
    [ :test, :development, :staging ].each do |deployment|
      assert_error(:unsupported_mode) do
        Integrations::ElevenLabs::Adapter.new(
          mode_policy: Integrations::ElevenLabs::ModePolicy.new(deployment: deployment, mode: :live),
          config: config_for
        )
      end
    end
  end

  test "live mode without credentials fails closed even with the capability marker" do
    adapter = Integrations::ElevenLabs::Adapter.new(
      mode_policy: live_policy(:development),
      config: config_for(api_key: nil),
      clock: -> { FROZEN_TIME },
      http_client: ->(**) { raise "must not be called" }
    )
    assert_error(:missing_credentials) { adapter.conversation_authorization }
  end

  test "live mode surfaces a typed error and never leaks the transport body" do
    adapter = Integrations::ElevenLabs::Adapter.new(
      mode_policy: live_policy(:development),
      config: config_for,
      clock: -> { FROZEN_TIME },
      http_client: ->(**) { raise "boom SYNTHETIC-SECRET" }
    )
    error = assert_error(:unavailable) { adapter.conversation_authorization }
    refute_includes error.message, "SYNTHETIC-SECRET"
  end

  test "live mode returns a typed result when the transport responds successfully" do
    adapter = Integrations::ElevenLabs::Adapter.new(
      mode_policy: live_policy(:development),
      config: config_for,
      clock: -> { FROZEN_TIME },
      http_client: ->(agent_id:, api_key:) { { "token" => "live-token-for-#{agent_id}" } }
    )
    result = adapter.conversation_authorization
    assert_equal "live-token-for-agent-123", result.conversation_token
    assert_equal FROZEN_TIME + Integrations::ElevenLabs::Adapter::TOKEN_TTL, result.expires_at
  end

  test "live mode rejects a malformed transport payload" do
    adapter = Integrations::ElevenLabs::Adapter.new(
      mode_policy: live_policy(:development),
      config: config_for,
      clock: -> { FROZEN_TIME },
      http_client: ->(**) { { "token" => 12345 } }
    )
    assert_error(:malformed_response) { adapter.conversation_authorization }
  end

  private

  def adapter_with(agent_id:)
    Integrations::ElevenLabs::Adapter.new(
      mode_policy: Integrations::ElevenLabs::ModePolicy.new(deployment: :test),
      config: config_for(agent_id: agent_id),
      clock: -> { FROZEN_TIME }
    )
  end

  def live_policy(deployment)
    Integrations::ElevenLabs::ModePolicy.new(deployment: deployment, mode: :live,
      capability: Integrations::ElevenLabs::ModePolicy::LIVE_CAPABILITY)
  end

  def config_for(api_key: "sk_test_key", agent_id: "agent-123", tool_secret: "tool-secret", webhook_secret: "webhook-secret")
    Integrations::ElevenLabs::Config.new(api_key:, agent_id:, tool_secret:, webhook_secret:)
  end

  def assert_error(code, &block)
    error = assert_raises(Integrations::ElevenLabs::Error, &block)
    assert_equal code, error.code
    error
  end
end
