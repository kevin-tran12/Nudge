require "test_helper"

# End-to-end seam between VOICE-01 and VOICE-02. Each package tested its own
# half, so nothing caught that the session endpoint returned the provider's
# conversation token while the tool endpoint expected the AI grant bearer.
# The widget cannot work unless the credential issued here is the credential
# accepted there, so this drives the real flow rather than a manufactured grant.
class VoiceSessionToToolTest < ActionDispatch::IntegrationTest
  include TestSupport::IdentityRecords

  ORIGIN = "http://www.example.com"

  setup do
    travel_to TestSupport::IdentityRecords::REFERENCE_TIME
    clear_identity_records
    @previous_eleven_labs_config = Rails.application.config.x.eleven_labs
    Rails.application.config.x.eleven_labs = Integrations::ElevenLabs::Config.new(
      api_key: nil, agent_id: "demo-agent-fixture", tool_secret: nil, webhook_secret: nil
    )
  end

  teardown do
    Rails.application.config.x.eleven_labs = @previous_eleven_labs_config
    clear_identity_records
    travel_back
  end

  test "a token issued by POST /voice/session authorizes a tool call" do
    post "/voice/session", headers: { "Origin" => ORIGIN }

    assert_response :created
    body = response.parsed_body
    grant_token = body.fetch("grant_token")

    assert grant_token.present?, "session endpoint must return the AI grant bearer token"
    refute_equal body.fetch("conversation_token"), grant_token,
      "the provider conversation token must not be reused as the application credential"

    post "/voice/tools/search_products",
      params: { "query" => "storage", "limit" => 5 },
      headers: { "Origin" => ORIGIN, "Authorization" => "Bearer #{grant_token}" },
      as: :json

    assert_response :success
    assert_operator response.parsed_body.fetch("count"), :>=, 1
  end

  test "the provider conversation token is rejected as a tool credential" do
    post "/voice/session", headers: { "Origin" => ORIGIN }
    assert_response :created

    post "/voice/tools/get_current_shopping_state",
      params: {},
      headers: {
        "Origin" => ORIGIN,
        "Authorization" => "Bearer #{response.parsed_body.fetch('conversation_token')}"
      },
      as: :json

    assert_response :unauthorized
    assert_equal "grant_required", response.parsed_body.dig("error", "code")
  end

  test "the grant issued for one visitor does not authorize another visitor's tool call" do
    post "/voice/session", headers: { "Origin" => ORIGIN }
    assert_response :created
    stolen = response.parsed_body.fetch("grant_token")

    reset!

    post "/voice/tools/get_current_shopping_state",
      params: {},
      headers: { "Origin" => ORIGIN, "Authorization" => "Bearer #{stolen}" },
      as: :json

    assert_response :unauthorized
  end
end
