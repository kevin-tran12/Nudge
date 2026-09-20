require "test_helper"

class IdentityModelsTest < ActiveSupport::TestCase
  include TestSupport::IdentityRecords

  test "models expose the approved relationships and explicit time predicates" do
    user = create_user
    session = create_shopping_session(user:)
    consent = create_consent(session:)
    verification = create_verification(session:)
    grant = AiAccessGrant.create!(
      shopping_session: session,
      disclosure_consent_record: consent,
      turnstile_verification: verification,
      grant_token_digest: Digest::SHA256.digest("grant"),
      issued_at: REFERENCE_TIME,
      expires_at: REFERENCE_TIME + 60.minutes
    )

    assert_equal user, session.user
    assert_equal session, consent.shopping_session
    assert_equal session, verification.shopping_session
    assert_equal session, grant.shopping_session
    assert session.active_at?(REFERENCE_TIME)
    refute session.active_at?(session.expires_at)
    assert grant.active_at?(REFERENCE_TIME + 59.minutes)
    refute grant.active_at?(grant.expires_at)
    assert User.locking_enabled?
    assert ShoppingSession.locking_enabled?
    assert AiAccessGrant.locking_enabled?
  end
end
