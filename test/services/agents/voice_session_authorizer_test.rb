require "test_helper"
require "digest"

class VoiceSessionAuthorizerTest < ActiveSupport::TestCase
  include TestSupport::IdentityRecords

  self.use_transactional_tests = false

  FROZEN_TIME = TestSupport::IdentityRecords::REFERENCE_TIME

  setup { clear_identity_records }
  teardown { clear_identity_records }

  test "bootstraps a guest session, consent, and verification, then returns a bounded provider token" do
    cookie = build_cookie

    assert_difference -> { ShoppingSession.count }, 1 do
      result = authorizer.call(cookie: cookie, context: nil, expected_hostname: "shop.example.test")

      assert_equal "fixture-token", result.conversation_token
      assert_equal "agent-123", result.agent_id
      assert_equal FROZEN_TIME + 15.minutes, result.expires_at
    end

    session = ShoppingSession.order(:id).last
    assert_equal FROZEN_TIME + Agents::VoiceSessionAuthorizer::DEMO_SESSION_LIFETIME, session.expires_at
    assert_equal 1, session.consent_records.current.count
    assert_equal Agents::VoiceSessionAuthorizer::DEMO_DISCLOSURE_POLICY_VERSION,
      session.consent_records.current.first.policy_version
    assert_equal 1, session.ai_access_grants.where(status: "active").count
  end

  test "the returned expiry is bounded by whichever of grant or provider token expires first" do
    session = create_shopping_session
    context = Identity::CurrentContext.new(clock: -> { FROZEN_TIME }).call(shopping_session: session)
    long_lived_adapter = Struct.new(:conversation_token, :agent_id, :expires_at) do
      def conversation_authorization
        self
      end
    end.new("fixture-token", "agent-123", FROZEN_TIME + 6.hours)

    result = authorizer(adapter: long_lived_adapter).call(
      cookie: build_cookie, context: context, expected_hostname: "shop.example.test"
    )

    assert_equal FROZEN_TIME + 60.minutes, result.expires_at
  end

  test "writes the bootstrapped session into the response cookie jar" do
    cookie = build_cookie
    authorizer.call(cookie: cookie, context: nil, expected_hostname: "shop.example.test")

    session = ShoppingSession.order(:id).last
    assert cookie.resolve
    assert_equal session.id, cookie.resolve.current_shopping_session.id
  end

  test "reuses an existing active session instead of creating a duplicate" do
    session = create_shopping_session
    context = Identity::CurrentContext.new(clock: -> { FROZEN_TIME }).call(shopping_session: session)

    assert_no_difference -> { ShoppingSession.count } do
      result = authorizer.call(cookie: build_cookie, context: context, expected_hostname: "shop.example.test")
      assert_equal "fixture-token", result.conversation_token
    end
    assert_equal session.id, AiAccessGrant.last.shopping_session_id
  end

  test "is refused outright in production and creates no records" do
    production_authorizer = authorizer(deployment: "production")

    assert_no_difference -> { ShoppingSession.count + ConsentRecord.count + TurnstileVerification.count + AiAccessGrant.count } do
      error = assert_raises(Agents::VoiceSessionAuthorizer::Error) do
        production_authorizer.call(cookie: build_cookie, context: nil, expected_hostname: "shop.example.test")
      end
      assert_equal :demo_mode_unavailable, error.code
    end
  end

  test "a second authorization on the same session does not create a second active grant" do
    session = create_shopping_session
    context = Identity::CurrentContext.new(clock: -> { FROZEN_TIME }).call(shopping_session: session)

    authorizer.call(cookie: build_cookie, context: context, expected_hostname: "shop.example.test")

    error = assert_raises(Agents::VoiceSessionAuthorizer::Error) do
      authorizer.call(cookie: build_cookie, context: context, expected_hostname: "shop.example.test")
    end
    assert_equal :grant_conflict, error.code
    assert_equal 1, AiAccessGrant.where(shopping_session: session, status: "active").count
  end

  test "rejects malformed input before touching the database" do
    assert_no_difference -> { ShoppingSession.count } do
      error = assert_raises(Agents::VoiceSessionAuthorizer::Error) do
        authorizer.call(cookie: build_cookie, context: nil, expected_hostname: "")
      end
      assert_equal :invalid_input, error.code

      error = assert_raises(Agents::VoiceSessionAuthorizer::Error) do
        authorizer.call(cookie: "not-a-cookie", context: nil, expected_hostname: "shop.example.test")
      end
      assert_equal :invalid_input, error.code
    end
  end

  test "translates a provider outage into a typed error without leaking the provider" do
    failing_adapter = Object.new
    def failing_adapter.conversation_authorization
      raise Integrations::ElevenLabs::Error.new(:unavailable)
    end

    error = assert_raises(Agents::VoiceSessionAuthorizer::Error) do
      authorizer(adapter: failing_adapter).call(cookie: build_cookie, context: nil, expected_hostname: "shop.example.test")
    end
    assert_equal :provider_unavailable, error.code
  end

  private

  def authorizer(deployment: "test", adapter: fake_adapter)
    Agents::VoiceSessionAuthorizer.new(
      clock: -> { FROZEN_TIME },
      verification_token_generator: -> { SecureRandom.hex(24) },
      issuer: Identity::AiGrantIssuer.new(clock: -> { FROZEN_TIME }, token_generator: -> { SecureRandom.urlsafe_base64(32) }),
      adapter: adapter,
      deployment: deployment
    )
  end

  def fake_adapter
    Struct.new(:conversation_token, :agent_id, :expires_at) do
      def conversation_authorization
        self
      end
    end.new("fixture-token", "agent-123", FROZEN_TIME + 15.minutes)
  end

  def build_cookie
    request = ActionDispatch::TestRequest.create
    jar = ActionDispatch::Cookies::CookieJar.build(request, {})
    Identity::BrowserSessionCookie.new(cookie_jar: jar, clock: -> { FROZEN_TIME }, secure: false, environment: "test")
  end
end
