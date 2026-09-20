require "test_helper"

class Voice::SessionsControllerTest < ActionDispatch::IntegrationTest
  include TestSupport::IdentityRecords

  # bin/rails test with no explicit file arguments boots the Rails app (running
  # config/initializers/eleven_labs.rb, which reads ENV once) before this file's
  # `require "test_helper"` ever executes, so a test-only ENV default set here
  # would arrive too late. Stub the already-booted app-wide config directly
  # instead, scoped to this file, so the real default wiring (Agents::
  # VoiceSessionAuthorizer.new -> Integrations::ElevenLabs::Adapter.new) is
  # exercised end-to-end in fixture mode with a deterministic, non-secret agent id.
  setup do
    travel_to TestSupport::IdentityRecords::REFERENCE_TIME
    clear_identity_records
    @previous_eleven_labs_config = Rails.application.config.x.eleven_labs
    Rails.application.config.x.eleven_labs = Integrations::ElevenLabs::Config.new(
      api_key: nil, agent_id: "demo-agent-fixture", tool_secret: nil, webhook_secret: nil, mode: "fixture"
    )
  end

  teardown do
    Rails.application.config.x.eleven_labs = @previous_eleven_labs_config
    clear_identity_records
    travel_back
  end

  test "issues a conversation token for a fresh guest and sets the session cookie" do
    assert_difference -> { ShoppingSession.count }, 1 do
      post "/voice/session"
    end

    assert_response :created
    body = response.parsed_body
    assert body.fetch("conversation_token").present?
    assert body.fetch("agent_id").present?
    assert body.fetch("expires_at").present?
    assert cookies[Identity::BrowserSessionCookie::COOKIE_NAME].present?
  end

  test "reuses the existing session on a subsequent call via the returned cookie" do
    post "/voice/session"
    assert_response :created
    first_session_count = ShoppingSession.count

    assert_no_difference -> { ShoppingSession.count } do
      post "/voice/session"
    end
    assert_equal first_session_count, ShoppingSession.count
    assert_response :conflict
    assert_equal "grant_conflict", response.parsed_body.fetch("error")
  end

  test "no request parameter header or body field can select an existing session" do
    other = create_shopping_session(user: create_user)

    post "/voice/session", params: {
      shopping_session_id: other.public_id,
      current_shopping_session: { public_id: other.public_id }
    }, headers: { "X-Shopping-Session" => other.public_id }

    assert_response :created
    assert_not_equal other.id, ShoppingSession.order(:id).last.id
  end

  test "never leaks internals on refusal" do
    post "/voice/session"
    post "/voice/session"

    assert_response :conflict
    body = response.parsed_body
    assert_equal [ "error" ], body.keys
    refute_includes response.body, "Identity::"
    refute_includes response.body, "app/services"
  end
end
