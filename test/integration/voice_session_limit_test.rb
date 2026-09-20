require "test_helper"

# A publicly reachable demonstration mints provider grants without a real
# challenge, so one shopper must not be able to start conversations in a loop.
class VoiceSessionLimitTest < ActionDispatch::IntegrationTest
  include TestSupport::IdentityRecords

  ORIGIN = "http://www.example.com"

  setup do
    travel_to TestSupport::IdentityRecords::REFERENCE_TIME
    clear_identity_records
    @previous = Rails.application.config.x.eleven_labs
    Rails.application.config.x.eleven_labs = Integrations::ElevenLabs::Config.new(
      api_key: nil, agent_id: "demo-agent-fixture", tool_secret: nil, webhook_secret: nil, mode: "fixture"
    )
  end

  teardown do
    Rails.application.config.x.eleven_labs = @previous
    clear_identity_records
    travel_back
  end

  test "a shopper may start the allowed number of voice sessions and no more" do
    Agents::VoiceSessionAuthorizer::MAX_GRANTS_PER_SESSION.times do |attempt|
      post "/voice/session", headers: { "Origin" => ORIGIN }
      assert_response :created, "attempt #{attempt + 1} should be allowed"
    end

    post "/voice/session", headers: { "Origin" => ORIGIN }

    assert_response :too_many_requests
    assert_equal "session_limit_reached", response.parsed_body.fetch("error")
  end

  test "revoking and reissuing cannot be used to reset the allowance" do
    Agents::VoiceSessionAuthorizer::MAX_GRANTS_PER_SESSION.times do
      post "/voice/session", headers: { "Origin" => ORIGIN }
      assert_response :created
    end

    session = ShoppingSession.order(:created_at).last
    session.ai_access_grants.update_all(status: "expired")

    post "/voice/session", headers: { "Origin" => ORIGIN }

    assert_response :too_many_requests,
      "the cap counts grants ever issued, not only live ones"
  end

  test "the refusal leaks no internals" do
    (Agents::VoiceSessionAuthorizer::MAX_GRANTS_PER_SESSION + 1).times do
      post "/voice/session", headers: { "Origin" => ORIGIN }
    end

    assert_equal [ "error" ], response.parsed_body.keys
    refute_includes response.body, "Identity::"
    refute_includes response.body, "app/services"
  end
end
