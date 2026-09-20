require "test_helper"

# A grant's raw token is returned once and only its digest is stored, so an
# interrupted first attempt leaves an active grant nobody can use. Without an
# explicit revoke, every retry is refused for the full grant lifetime.
class VoiceSessionReauthorizationTest < ActionDispatch::IntegrationTest
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

  test "retrying after an interrupted attempt issues a usable grant instead of refusing" do
    post "/voice/session", headers: { "Origin" => ORIGIN }
    assert_response :created
    first_token = response.parsed_body.fetch("grant_token")

    post "/voice/session", headers: { "Origin" => ORIGIN }

    assert_response :created, "a second authorization must not be refused with a conflict"
    second_token = response.parsed_body.fetch("grant_token")
    refute_equal first_token, second_token, "re-authorization must mint a fresh token"
  end

  test "re-authorization preserves the one-active-grant invariant" do
    post "/voice/session", headers: { "Origin" => ORIGIN }
    assert_response :created
    post "/voice/session", headers: { "Origin" => ORIGIN }
    assert_response :created

    session = ShoppingSession.order(:created_at).last

    assert_equal 1, session.ai_access_grants.where(status: "active").count
    assert_equal 1, session.ai_access_grants.where(status: "expired").count
  end

  test "the superseded token no longer authorizes a tool call" do
    post "/voice/session", headers: { "Origin" => ORIGIN }
    assert_response :created
    stale = response.parsed_body.fetch("grant_token")

    post "/voice/session", headers: { "Origin" => ORIGIN }
    assert_response :created
    fresh = response.parsed_body.fetch("grant_token")

    post "/voice/tools/get_current_shopping_state", params: {},
      headers: { "Origin" => ORIGIN, "Authorization" => "Bearer #{stale}" }, as: :json
    assert_response :unauthorized, "a revoked grant must not keep working"

    post "/voice/tools/get_current_shopping_state", params: {},
      headers: { "Origin" => ORIGIN, "Authorization" => "Bearer #{fresh}" }, as: :json
    assert_response :success
  end
end
