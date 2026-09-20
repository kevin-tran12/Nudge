require "test_helper"
require "base64"
require "digest"
require "json"
require "logger"
require "stringio"
require "yaml"

class IdentityCoreTest < ActiveSupport::TestCase
  include TestSupport::IdentityRecords

  self.use_transactional_tests = false

  setup { clear_identity_records }
  teardown { clear_identity_records }

  test "trusted context derives its user only from an active unexpired shopping session" do
    first_user = create_user
    second_user = create_user
    session = create_shopping_session(user: first_user)

    context = Identity::CurrentContext.new(clock: -> { REFERENCE_TIME }).call(shopping_session: session)

    assert_equal session, context.current_shopping_session
    assert_equal first_user, context.current_user
    refute_equal second_user, context.current_user
    assert_raises(ArgumentError) { Identity::CurrentContext.new.call(shopping_session_id: session.id) }

    session.update!(status: "blocked")
    assert_identity_error(:session_inactive) do
      Identity::CurrentContext.new(clock: -> { REFERENCE_TIME }).call(shopping_session: session)
    end

    session.update!(status: "active", expires_at: REFERENCE_TIME)
    assert_identity_error(:session_expired) do
      Identity::CurrentContext.new(clock: -> { REFERENCE_TIME }).call(shopping_session: session)
    end
  end

  test "consent recording is session-bound versioned idempotent and history preserving" do
    user = create_user
    other_user = create_user
    session = create_shopping_session(user:)
    recorder = Identity::ConsentRecorder.new(clock: -> { REFERENCE_TIME })
    attributes = {
      shopping_session: session,
      policy_version: "disclosure-v1",
      decision: "accepted",
      scope_json: { provider: "elevenlabs" },
      scope_schema_version: 1
    }

    first = recorder.call(**attributes)
    repeated = recorder.call(**attributes)
    replacement = recorder.call(**attributes.merge(decision: "rejected"))
    next_version = recorder.call(**attributes.merge(policy_version: "disclosure-v2"))

    assert first.created
    refute repeated.created
    assert_equal first.record.id, repeated.record.id
    assert_equal user.id, first.record.user_id
    refute_equal other_user.id, first.record.user_id
    assert_equal REFERENCE_TIME, first.record.reload.withdrawn_at
    assert_equal "rejected", replacement.record.decision
    assert_nil replacement.record.withdrawn_at
    assert_equal "disclosure-v2", next_version.record.policy_version
    assert_equal 3, session.consent_records.count
    assert_equal 2, session.consent_records.where(withdrawn_at: nil).count
  end

  test "consent replacement rolls back the withdrawal when the new record cannot persist" do
    session = create_shopping_session
    current = create_consent(session:)
    recorder = Identity::ConsentRecorder.new(
      clock: -> { REFERENCE_TIME }, correlation_id_generator: -> { "not-a-uuid" }
    )

    assert_identity_error(:invalid_input) do
      recorder.call(
        shopping_session: session,
        policy_version: current.policy_version,
        decision: "rejected",
        scope_json: {},
        scope_schema_version: 1
      )
    end

    assert_nil current.reload.withdrawn_at
    assert_equal 1, ConsentRecord.where(shopping_session: session).count
  end

  test "identical concurrent consent writes return one active durable record" do
    session = create_shopping_session
    starts = Queue.new
    outcomes = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          starts.pop
          record = Identity::ConsentRecorder.new(clock: -> { REFERENCE_TIME }).call(
            shopping_session: ShoppingSession.find(session.id),
            policy_version: "disclosure-v1",
            decision: "accepted",
            scope_json: {},
            scope_schema_version: 1
          )
          outcomes << record.record.id
        rescue StandardError => error
          outcomes << error
        end
      end
    end
    2.times { starts << true }
    threads.each(&:join)
    values = 2.times.map { outcomes.pop }

    assert values.none?(Exception), values.map(&:inspect).join("\n")
    assert_equal 1, values.uniq.length
    assert_equal 1, ConsentRecord.where(shopping_session: session, withdrawn_at: nil).count
  end

  test "issuer creates a same-session absolute grant and returns the bearer token once without serialization leaks" do
    session = create_shopping_session
    consent = create_consent(session:)
    verification = create_verification(session:)
    issuer = issuer_at(REFERENCE_TIME, token: "one-time-bearer-token-with-enough-entropy")

    result = issuer.call(
      shopping_session: session,
      disclosure_policy_version: consent.policy_version,
      turnstile_verification: verification,
      expected_action: "ai_grant",
      expected_hostname: "shop.example.test"
    )

    grant = result.grant.reload
    assert_equal "one-time-bearer-token-with-enough-entropy", result.bearer_token
    assert_equal Digest::SHA256.digest(result.bearer_token), grant.grant_token_digest
    assert_equal REFERENCE_TIME, grant.issued_at
    assert_equal REFERENCE_TIME + 60.minutes, grant.expires_at
    assert_equal session.id, grant.shopping_session_id
    assert_equal consent.id, grant.disclosure_consent_record_id
    assert_equal verification.id, grant.turnstile_verification_id
    assert_result_redacted(result, result.bearer_token)
  end

  test "identity results redact direct nested interpolation and logging while preserving deliberate token access" do
    user = create_user
    session = create_shopping_session(user:)
    consent = create_consent(session:)
    verification = create_verification(session:)
    issued = issue(issuer_at(REFERENCE_TIME, token: "string-log-sentinel-bearer-token-value"),
      session, consent.policy_version, verification)
    context = Identity::CurrentContext.new(clock: -> { REFERENCE_TIME }).call(shopping_session: session)
    recorded = Identity::ConsentRecorder.new(clock: -> { REFERENCE_TIME }).call(
      shopping_session: session,
      policy_version: "disclosure-v2",
      decision: "accepted",
      scope_json: { "private" => "scope-log-sentinel" },
      scope_schema_version: 1
    )
    authorization = authorizer_at.call(shopping_session: session, bearer_token: issued.bearer_token)
    output = StringIO.new
    logger = Logger.new(output)

    sentinels = [ issued.bearer_token, issued.grant.public_id, session.public_id,
      user.public_id, "scope-log-sentinel" ]
    [ issued, context, recorded, authorization ].each do |result|
      forms = [ result.to_s, "result=#{result}", "nested=#{[ { result: } ]}" ]
      logger.info(result)
      forms.each do |form|
        sentinels.each { |sentinel| refute_includes form, sentinel }
      end
    end

    sentinels.each { |sentinel| refute_includes output.string, sentinel }
    assert_equal "string-log-sentinel-bearer-token-value", issued.bearer_token
  end

  test "issuer captures one instant for session consent verification and grant timestamps" do
    session = create_shopping_session(
      started_at: REFERENCE_TIME,
      expires_at: REFERENCE_TIME + 1.second
    )
    consent = create_consent(session:, recorded_at: REFERENCE_TIME)
    verification = create_verification(session:, challenge_timestamp: REFERENCE_TIME,
      validated_at: REFERENCE_TIME, expires_at: REFERENCE_TIME + 1.second)
    clock = sequential_clock(REFERENCE_TIME, REFERENCE_TIME + 2.seconds)

    result = Identity::AiGrantIssuer.new(clock:, token_generator: -> { "single-clock-token-with-enough-entropy" }).call(
      shopping_session: session,
      disclosure_policy_version: consent.policy_version,
      turnstile_verification: verification,
      expected_action: "ai_grant",
      expected_hostname: "shop.example.test"
    )

    assert_equal REFERENCE_TIME, result.grant.issued_at
    assert_equal REFERENCE_TIME + 60.minutes, result.grant.expires_at
    assert_equal 1, clock.calls
  end

  test "consent and authorization use one locked instant at expiry boundaries without partial writes" do
    session = create_shopping_session(started_at: REFERENCE_TIME - 1.minute,
      expires_at: REFERENCE_TIME + 1.second)
    consent_clock = sequential_clock(REFERENCE_TIME + 1.second, REFERENCE_TIME)

    assert_identity_error(:session_expired) do
      Identity::ConsentRecorder.new(clock: consent_clock).call(
        shopping_session: session,
        policy_version: "disclosure-v1",
        decision: "accepted",
        scope_json: {},
        scope_schema_version: 1
      )
    end
    assert_equal 1, consent_clock.calls
    assert_equal 0, ConsentRecord.count

    session.update!(expires_at: REFERENCE_TIME + 2.hours)
    consent = create_consent(session:)
    verification = create_verification(session:)
    issued = issue(issuer_at, session, consent.policy_version, verification)
    authorization_clock = sequential_clock(issued.grant.expires_at, REFERENCE_TIME)

    assert_identity_error(:grant_inactive) do
      Identity::AiGrantAuthorizer.new(clock: authorization_clock).call(
        shopping_session: session, bearer_token: issued.bearer_token
      )
    end
    assert_equal 1, authorization_clock.calls
    assert_equal "expired", issued.grant.reload.status
  end

  test "future session starts and future consent records fail closed without grants" do
    future_session = create_shopping_session(started_at: REFERENCE_TIME + 1.second)
    assert_identity_error(:session_inactive) do
      Identity::CurrentContext.new(clock: -> { REFERENCE_TIME }).call(shopping_session: future_session)
    end

    session = create_shopping_session
    consent = create_consent(session:, recorded_at: REFERENCE_TIME + 1.second)
    verification = create_verification(session:)
    assert_identity_error(:consent_required) do
      issue(issuer_at, session, consent.policy_version, verification)
    end
    assert_equal 0, AiAccessGrant.count
    assert_nil consent.reload.withdrawn_at
  end

  test "consent scope rejects cyclic deep oversized wide and unsupported JSON without changing history" do
    session = create_shopping_session
    current = create_consent(session:)
    recorder = Identity::ConsentRecorder.new(clock: -> { REFERENCE_TIME })
    cyclic = {}
    cyclic["self"] = cyclic
    deep = {}
    cursor = deep
    10.times { cursor["next"] = {}; cursor = cursor["next"] }
    invalid_scopes = [
      cyclic,
      deep,
      { "large" => "x" * 9_000 },
      { "wide" => Array.new(65, true) },
      { "duplicate" => { "key" => true, key: false } },
      { "unsupported" => Time.now },
      { "non_finite" => Float::INFINITY }
    ]

    invalid_scopes.each do |scope|
      assert_identity_error(:invalid_input) do
        recorder.call(
          shopping_session: session,
          policy_version: current.policy_version,
          decision: "rejected",
          scope_json: scope,
          scope_schema_version: 1
        )
      end
    end

    assert_equal 1, ConsentRecord.count
    assert_nil current.reload.withdrawn_at
  end

  test "issuer rejects invalid session consent and Turnstile evidence with stable sanitized errors" do
    session = create_shopping_session
    other_session = create_shopping_session
    consent = create_consent(session:)
    valid = create_verification(session:)

    cases = {
      consent_required: -> { issue(issuer_at, session, "other-version", valid) },
      verification_failed: -> { issue(issuer_at, session, consent.policy_version, create_verification(session:, success: false)) },
      verification_expired: -> {
        expired = create_verification(session:, validated_at: REFERENCE_TIME - 5.minutes,
          challenge_timestamp: REFERENCE_TIME - 5.minutes, expires_at: REFERENCE_TIME - 1.second)
        issue(issuer_at, session, consent.policy_version, expired)
      },
      verification_mismatch: -> {
        mismatch = create_verification(session:, action: "other")
        issue(issuer_at, session, consent.policy_version, mismatch)
      },
      verification_wrong_session: -> {
        other = create_verification(session: other_session)
        issue(issuer_at, session, consent.policy_version, other)
      }
    }

    cases.each do |code, operation|
      expected = code == :verification_wrong_session ? :verification_mismatch : code
      assert_identity_error(expected, &operation)
    end
    assert_equal 0, AiAccessGrant.count
  end

  test "one verification is single use even after its prior grant expires" do
    session = create_shopping_session
    consent = create_consent(session:)
    verification = create_verification(session:)
    issue(issuer_at, session, consent.policy_version, verification)
    AiAccessGrant.update_all(status: "expired")

    assert_identity_error(:verification_replayed) do
      issue(issuer_at(REFERENCE_TIME + 1.minute), session, consent.policy_version, verification)
    end
    assert_equal 1, AiAccessGrant.count
  end

  test "rejected or withdrawn disclosure cannot authorize a grant" do
    session = create_shopping_session
    rejected = create_consent(session:, decision: "rejected")
    verification = create_verification(session:)

    assert_identity_error(:consent_required) do
      issue(issuer_at, session, rejected.policy_version, verification)
    end

    rejected.update!(decision: "accepted", withdrawn_at: REFERENCE_TIME)
    assert_identity_error(:consent_required) do
      issue(issuer_at, session, rejected.policy_version, verification)
    end
    assert_equal 0, AiAccessGrant.count
  end

  test "default issuer generates unique high entropy bearer tokens" do
    results = 2.times.map do |index|
      session = create_shopping_session
      consent = create_consent(session:, policy_version: "disclosure-v#{index}")
      verification = create_verification(session:)
      issue(Identity::AiGrantIssuer.new(clock: -> { REFERENCE_TIME }),
        session, consent.policy_version, verification)
    end

    assert_equal 2, results.map(&:bearer_token).uniq.length
    results.each { |result| assert_operator result.bearer_token.bytesize, :>=, 32 }
    assert_equal 2, AiAccessGrant.distinct.count(:grant_token_digest)
  end

  test "concurrent issuers leave one active grant and translate the losing race" do
    session = create_shopping_session
    consent = create_consent(session:)
    verifications = [ create_verification(session:), create_verification(session:) ]
    starts = Queue.new
    outcomes = Queue.new

    threads = verifications.each_with_index.map do |verification, index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          starts.pop
          result = issue(
            issuer_at(REFERENCE_TIME, token: "concurrent-bearer-token-#{index}-with-entropy"),
            ShoppingSession.find(session.id), consent.policy_version, TurnstileVerification.find(verification.id)
          )
          outcomes << result
        rescue StandardError => error
          outcomes << error
        end
      end
    end
    2.times { starts << true }
    threads.each(&:join)
    values = 2.times.map { outcomes.pop }

    assert_equal 1, values.count { |value| value.is_a?(Identity::AiGrantIssuer::Result) }
    error = values.find { |value| value.is_a?(Identity::Error) }
    assert_equal :active_grant_exists, error&.code
    assert_nil error&.cause
    assert_equal 1, AiAccessGrant.where(shopping_session: session, status: "active").count
  end

  test "authorizer fails closed at exact expiry and across sessions or inactive states" do
    session = create_shopping_session
    other_session = create_shopping_session
    consent = create_consent(session:)
    verification = create_verification(session:)
    issued = issue(issuer_at, session, consent.policy_version, verification)

    authorized = authorizer_at(REFERENCE_TIME + 59.minutes).call(
      shopping_session: session, bearer_token: issued.bearer_token
    )
    assert_equal issued.grant, authorized.grant
    assert_equal({ "authorized" => true }, authorized.as_json)
    assert_identity_error(:unauthorized_grant) do
      authorizer_at.call(shopping_session: other_session, bearer_token: issued.bearer_token)
    end
    assert_identity_error(:grant_inactive) do
      authorizer_at(issued.grant.expires_at).call(shopping_session: session, bearer_token: issued.bearer_token)
    end
    assert_equal "expired", issued.grant.reload.status

    %w[revoked terminated].each do |status|
      issued.grant.update!(status:, revoked_at: (REFERENCE_TIME if status == "revoked"))
      assert_identity_error(:grant_inactive) do
        authorizer_at.call(shopping_session: session, bearer_token: issued.bearer_token)
      end
    end
  end

  test "issuer rolls back status changes and removes dependency details when token generation fails" do
    session = create_shopping_session
    consent = create_consent(session:)
    verification = create_verification(session:)
    expired_grant = AiAccessGrant.create!(
      shopping_session: session,
      disclosure_consent_record: consent,
      grant_token_digest: Digest::SHA256.digest("old"),
      issued_at: REFERENCE_TIME - 61.minutes,
      expires_at: REFERENCE_TIME - 1.minute
    )
    issuer = Identity::AiGrantIssuer.new(
      clock: -> { REFERENCE_TIME }, token_generator: -> { raise "synthetic-secret generator failure" }
    )

    error = assert_identity_error(:conflict) do
      issuer.call(
        shopping_session: session,
        disclosure_policy_version: consent.policy_version,
        turnstile_verification: verification,
        expected_action: "ai_grant",
        expected_hostname: "shop.example.test"
      )
    end

    assert_equal "active", expired_grant.reload.status
    assert_nil error.cause
    refute_includes error.full_message, "synthetic-secret"
    assert_equal 1, AiAccessGrant.count
  end

  test "context consent and authorization results expose no record graph through serializers" do
    user = create_user
    session = create_shopping_session(user:)
    context = Identity::CurrentContext.new(clock: -> { REFERENCE_TIME }).call(shopping_session: session)
    consent = Identity::ConsentRecorder.new(clock: -> { REFERENCE_TIME }).call(
      shopping_session: session,
      policy_version: "disclosure-v1",
      decision: "accepted",
      scope_json: { private_marker: "synthetic-private-marker" },
      scope_schema_version: 1
    )
    verification = create_verification(session:)
    issued = issue(issuer_at, session, consent.record.policy_version, verification)
    authorization = authorizer_at.call(shopping_session: session, bearer_token: issued.bearer_token)

    [ context, consent, authorization ].each do |result|
      serialized = [ result.inspect, result.to_json, JSON.generate(value: [ result ]) ]
      serialized.each do |value|
        refute_includes value, session.public_id
        refute_includes value, user.public_id
        refute_includes value, "synthetic-private-marker"
      end
      [ -> { YAML.dump(value: [ result ]) }, -> { Marshal.dump(value: [ result ]) } ].each do |serialize|
        error = assert_raises(TypeError, &serialize)
        refute_includes error.full_message, session.public_id
      end
    end
  end

  test "identity errors serialize only their stable code and refuse object serializers" do
    session = create_shopping_session(status: "blocked")
    error = assert_identity_error(:session_inactive) do
      Identity::CurrentContext.new(clock: -> { REFERENCE_TIME }).call(shopping_session: session)
    end

    assert_equal({ "code" => "session_inactive" }, error.as_json)
    assert_equal({ "code" => "session_inactive" }, JSON.parse(error.to_json))
    assert_equal({ "error" => { "code" => "session_inactive" } }, JSON.parse(JSON.generate(error:)))
    assert_raises(TypeError) { YAML.dump(error:) }
    assert_raises(TypeError) { Marshal.dump(error:) }
  end

  private
    def issuer_at(time = REFERENCE_TIME, token: nil)
      generator = token ? -> { token } : -> { "default-bearer-token-with-enough-entropy" }
      Identity::AiGrantIssuer.new(clock: -> { time }, token_generator: generator)
    end

    def authorizer_at(time = REFERENCE_TIME)
      Identity::AiGrantAuthorizer.new(clock: -> { time })
    end

    def issue(issuer, session, policy_version, verification)
      issuer.call(
        shopping_session: session,
        disclosure_policy_version: policy_version,
        turnstile_verification: verification,
        expected_action: "ai_grant",
        expected_hostname: "shop.example.test"
      )
    end

    def assert_identity_error(code, &block)
      error = assert_raises(Identity::Error, &block)
      assert_equal code, error.code
      assert_equal "Identity: #{code}", error.message
      assert_nil error.cause
      error
    end

    def assert_result_redacted(result, token)
      forms = [ result.inspect, result.to_s, "#{result}", result.as_json.to_json, result.to_json,
        JSON.generate(result), ActiveSupport::JSON.encode(value: [ result ]) ]
      forms.each { |serialized| refute_includes serialized, token }

      [ -> { YAML.dump(result) }, -> { YAML.dump(value: [ result ]) },
        -> { Marshal.dump(result) }, -> { Marshal.dump(value: [ result ]) } ].each do |serialize|
        error = assert_raises(TypeError, &serialize)
        refute_includes error.full_message, token
      end
    end

    def sequential_clock(*times)
      Class.new do
        attr_reader :calls

        define_method(:initialize) do |values|
          @values = values
          @calls = 0
        end

        define_method(:call) do
          value = @values.fetch(@calls)
          @calls += 1
          value
        end
      end.new(times)
    end
end
