require "test_helper"
require "digest"
require "pg"
require "tempfile"

class IdentitySchemaTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TABLES = %w[
    agent_provider_sessions
    ai_access_grants
    turnstile_verifications
    consent_records
    shopping_sessions
    external_identities
    users
  ].freeze

  setup { truncate_identity_tables }
  teardown { truncate_identity_tables }

  test "creates exactly the approved identity tables without raw credentials or Turnstile material" do
    expected_columns = {
      "users" => %w[id public_id status email_ciphertext email_lookup_digest email_digest_key_version locale region_code last_authenticated_at lock_version created_at updated_at],
      "external_identities" => %w[id user_id provider provider_subject_ciphertext provider_subject_digest digest_key_version email_verified_at claims_version last_authenticated_at encryption_context created_at updated_at],
      "shopping_sessions" => %w[id public_id user_id status started_at last_activity_at expires_at coarse_region_code abuse_level lock_version created_at updated_at],
      "consent_records" => %w[id shopping_session_id user_id consent_kind policy_version decision scope_json scope_schema_version recorded_at withdrawn_at correlation_id created_at updated_at],
      "turnstile_verifications" => %w[id shopping_session_id token_digest expected_action validated_hostname success failure_code challenge_timestamp validated_at expires_at source_key_digest source_key_version purge_after created_at updated_at],
      "ai_access_grants" => %w[id public_id shopping_session_id grant_token_digest status disclosure_consent_record_id turnstile_verification_id verification_reason_snapshot issued_at expires_at revoked_at revocation_reason_code lock_version created_at updated_at],
      "agent_provider_sessions" => %w[id ai_access_grant_id shopping_session_id provider provider_session_ref_ciphertext provider_session_ref_digest digest_key_version status started_at ended_at last_event_at termination_reason lock_version encryption_context created_at updated_at]
    }

    expected_columns.each do |table, columns|
      assert_equal columns.sort, connection.columns(table).map(&:name).sort, table
    end

    all_columns = expected_columns.values.flatten
    refute_includes all_columns, "password_digest"
    refute_includes all_columns, "raw_token"
    refute_includes all_columns, "ip_address"
  end

  test "keeps pgvector 0.8.5 pinned when Active Record automatically dumps after migration" do
    Tempfile.create([ "db02-structure", ".sql" ]) do |file|
      previous_schema = ENV["SCHEMA"]
      ENV["SCHEMA"] = file.path

      ActiveRecord::Tasks::DatabaseTasks.dump_schema(ActiveRecord::Base.connection_db_config, :sql)

      assert_includes File.read(file.path), Nudge::DatabaseCompatibility::PGVECTOR_STRUCTURE_STATEMENT
    ensure
      ENV["SCHEMA"] = previous_schema
    end
  end

  test "uses PostgreSQL UUID defaults, timestamptz timestamps, and nonnegative lock versions" do
    user_id = insert_user
    session_id = insert_session(user_id: user_id)

    assert_match(/gen_random_uuid/, column_default("users", "public_id"))
    assert_match(/gen_random_uuid/, column_default("shopping_sessions", "public_id"))
    assert_match(/gen_random_uuid/, column_default("external_identities", "encryption_context"))

    TABLES.each do |table|
      timestamp_columns(table).each do |column|
        assert_equal "timestamp with time zone", column.fetch("data_type"), "#{table}.#{column.fetch("column_name")}"
      end
    end

    assert_constraint { execute("UPDATE users SET lock_version = -1 WHERE id = #{user_id}") }
    assert_constraint { execute("UPDATE shopping_sessions SET lock_version = -1 WHERE id = #{session_id}") }
  end

  test "enforces user email digest pairing, length, key version, and rotated-key uniqueness" do
    assert_constraint { insert_user(email_digest: digest("short")[0, 16], email_key: 1) }
    assert_constraint { insert_user(email_digest: digest("missing-key"), email_key: nil) }
    assert_constraint { insert_user(email_digest: nil, email_key: 1) }
    assert_constraint { insert_user(email_digest: digest("bad-version"), email_key: 0) }

    insert_user(email_digest: digest("same-email"), email_key: 1)
    assert_constraint(unique: true) { insert_user(email_digest: digest("same-email"), email_key: 1) }
    assert insert_user(email_digest: digest("same-email"), email_key: 2)
  end

  test "enforces external identity digest constraints and cascades identities with the user" do
    user_id = insert_user
    insert_external_identity(user_id: user_id, subject: "subject-a")

    assert_constraint { insert_external_identity(user_id: user_id, subject: "short", digest_override: digest("short")[0, 8]) }
    assert_constraint { insert_external_identity(user_id: user_id, subject: "bad-key", key_version: 0) }
    assert_constraint { insert_external_identity(user_id: user_id, subject: "bad-provider", provider: "github") }
    assert_constraint { insert_external_identity(user_id: user_id, subject: "bad-claims", claims_version: 0) }
    assert_constraint(unique: true) { insert_external_identity(user_id: user_id, subject: "subject-a") }
    assert insert_external_identity(user_id: user_id, subject: "subject-a", key_version: 2)

    execute("DELETE FROM users WHERE id = #{user_id}")
    assert_equal 0, select_value("SELECT count(*) FROM external_identities").to_i
  end

  test "enforces shopping session lifecycle bounds and nulls optional user ownership" do
    user_id = insert_user
    session_id = insert_session(user_id: user_id)
    consent_id = insert_consent(session_id: session_id, user_id: user_id)

    assert_constraint { insert_session(status: "unknown") }
    assert_constraint { insert_session(abuse_level: 5) }
    assert_constraint { insert_session(abuse_level: -1) }
    assert_constraint { insert_session(started_at: reference_time, expires_at: reference_time) }

    execute("DELETE FROM users WHERE id = #{user_id}")
    assert_nil select_value("SELECT user_id FROM shopping_sessions WHERE id = #{session_id}")
    assert_nil select_value("SELECT user_id FROM consent_records WHERE id = #{consent_id}")
  end

  test "retains consent history while allowing only one active policy decision" do
    session_id = insert_session
    consent_id = insert_consent(session_id: session_id)

    assert_constraint(unique: true) { insert_consent(session_id: session_id) }
    execute("UPDATE consent_records SET withdrawn_at = #{q(reference_time + 60)} WHERE id = #{consent_id}")
    replacement_id = insert_consent(session_id: session_id)
    assert_operator replacement_id, :>, consent_id
    assert insert_consent(session_id: session_id, withdrawn_at: reference_time + 120)
    assert_constraint { insert_consent(session_id: session_id, scope_json: "[]") }
    assert_constraint { insert_consent(session_id: session_id, scope_schema_version: 0) }
    assert_constraint { insert_consent(session_id: session_id, withdrawn_at: reference_time - 1) }
    assert_constraint { insert_consent(session_id: session_id, kind: "marketing") }
    assert_constraint { insert_consent(session_id: session_id, decision: "implicit") }

    assert_constraint(foreign_key: true) { execute("DELETE FROM shopping_sessions WHERE id = #{session_id}") }
    assert_equal 3, select_value("SELECT count(*) FROM consent_records").to_i
  end

  test "enforces Turnstile token replay, digest pairing, expiry, and purge metadata" do
    session_id = insert_session
    verification_id = insert_turnstile(session_id: session_id, token: "token-a")

    assert_constraint(unique: true) { insert_turnstile(session_id: session_id, token: "token-a") }
    assert_constraint { insert_turnstile(session_id: session_id, token: "short", token_digest: digest("short")[0, 12]) }
    assert_constraint { insert_turnstile(session_id: session_id, token: "late", expires_at: reference_time + 301) }
    assert_constraint { insert_turnstile(session_id: session_id, token: "source-digest-only", source_digest: digest("source")) }
    assert_constraint { insert_turnstile(session_id: session_id, token: "source-version-only", source_version: 1) }
    assert_constraint { insert_turnstile(session_id: session_id, token: "source-short", source_digest: digest("source")[0, 12], source_version: 1) }
    assert_constraint { insert_turnstile(session_id: session_id, token: "source-key-zero", source_digest: digest("source"), source_version: 0) }

    execute("DELETE FROM turnstile_verifications WHERE id = #{verification_id}")
    assert_equal 0, select_value("SELECT count(*) FROM turnstile_verifications").to_i
  end

  test "binds grants to same-session consent and Turnstile evidence and makes verification single-use" do
    session_a = insert_session
    session_b = insert_session
    consent_a = insert_consent(session_id: session_a)
    consent_b = insert_consent(session_id: session_b)
    verification_a = insert_turnstile(session_id: session_a, token: "session-a")
    verification_b = insert_turnstile(session_id: session_b, token: "session-b")

    grant_id = insert_grant(session_id: session_a, consent_id: consent_a, verification_id: verification_a)
    assert_constraint(foreign_key: true) do
      insert_grant(session_id: session_a, consent_id: consent_b, verification_id: nil, token: "cross-consent", status: "expired")
    end
    assert_constraint(foreign_key: true) do
      insert_grant(
        session_id: session_a,
        consent_id: consent_a,
        verification_id: verification_b,
        token: "cross-turnstile",
        status: "expired"
      )
    end
    assert_constraint(unique: true) do
      insert_grant(session_id: session_b, consent_id: consent_b, verification_id: verification_a, token: "replay")
    end

    execute("DELETE FROM turnstile_verifications WHERE id = #{verification_a}")
    assert_nil select_value("SELECT turnstile_verification_id FROM ai_access_grants WHERE id = #{grant_id}")
  end

  test "enforces grant duration, digest, status, and one active grant under a race" do
    session_id = insert_session
    consent_id = insert_consent(session_id: session_id)

    assert_constraint { insert_grant(session_id: session_id, consent_id: consent_id, token: "short", token_digest: digest("short")[0, 10]) }
    assert_constraint { insert_grant(session_id: session_id, consent_id: consent_id, token: "zero", expires_at: reference_time) }
    assert_constraint { insert_grant(session_id: session_id, consent_id: consent_id, token: "long", expires_at: reference_time + 3601) }
    assert_constraint { insert_grant(session_id: session_id, consent_id: consent_id, token: "bad-status", status: "pending") }
    assert_constraint { insert_grant(session_id: session_id, consent_id: consent_id, token: "bad-lock", lock_version: -1) }

    results = concurrent_inserts([
      grant_sql(session_id: session_id, consent_id: consent_id, token: "race-a"),
      grant_sql(session_id: session_id, consent_id: consent_id, token: "race-b")
    ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)
  end

  test "binds provider sessions to their grant session and enforces reference and lifecycle checks" do
    session_a = insert_session
    session_b = insert_session
    consent_a = insert_consent(session_id: session_a)
    grant_a = insert_grant(session_id: session_a, consent_id: consent_a)

    insert_provider_session(grant_id: grant_a, session_id: session_a, ref: "provider-a")
    assert_constraint(foreign_key: true) do
      insert_provider_session(grant_id: grant_a, session_id: session_b, status: "ended", ref: "cross-session", ended_at: reference_time + 1)
    end
    assert_constraint { insert_provider_session(grant_id: grant_a, session_id: session_a, provider: "other", status: "ended", ref: "provider-b", ended_at: reference_time + 1) }
    assert_constraint { insert_provider_session(grant_id: grant_a, session_id: session_a, status: "unknown", ref: "provider-c") }
    assert_constraint { insert_provider_session(grant_id: grant_a, session_id: session_a, status: "ended", ref: "provider-d", ended_at: reference_time - 1) }
    assert_constraint { insert_provider_session(grant_id: grant_a, session_id: session_a, status: "ended", ref: "provider-e", ref_digest: nil, key_version: 1, ended_at: reference_time + 1) }
    assert_constraint { insert_provider_session(grant_id: grant_a, session_id: session_a, status: "ended", ref: nil, ref_digest: digest("orphan"), key_version: 1, ended_at: reference_time + 1) }
    assert_constraint { insert_provider_session(grant_id: grant_a, session_id: session_a, status: "ended", ref: "short", ref_digest: digest("short")[0, 10], key_version: 1, ended_at: reference_time + 1) }
  end

  test "allows only one starting or active provider session under a race" do
    session_id = insert_session
    consent_id = insert_consent(session_id: session_id)
    grant_id = insert_grant(session_id: session_id, consent_id: consent_id)

    results = concurrent_inserts([
      provider_session_sql(grant_id: grant_id, session_id: session_id, ref: "race-a"),
      provider_session_sql(grant_id: grant_id, session_id: session_id, ref: "race-b")
    ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)
  end

  test "applies the approved delete graph for sessions, grants, consent, and provider sessions" do
    session_id = insert_session
    consent_id = insert_consent(session_id: session_id)
    verification_id = insert_turnstile(session_id: session_id)
    grant_id = insert_grant(session_id: session_id, consent_id: consent_id, verification_id: verification_id)
    provider_session_id = insert_provider_session(grant_id: grant_id, session_id: session_id)

    assert_constraint(foreign_key: true) { execute("DELETE FROM ai_access_grants WHERE id = #{grant_id}") }
    assert_constraint(foreign_key: true) { execute("DELETE FROM consent_records WHERE id = #{consent_id}") }
    assert_constraint(foreign_key: true) { execute("DELETE FROM shopping_sessions WHERE id = #{session_id}") }

    execute("DELETE FROM agent_provider_sessions WHERE id = #{provider_session_id}")
    execute("DELETE FROM ai_access_grants WHERE id = #{grant_id}")
    execute("DELETE FROM consent_records WHERE id = #{consent_id}")
    execute("DELETE FROM shopping_sessions WHERE id = #{session_id}")
    assert_equal 0, select_value("SELECT count(*) FROM turnstile_verifications").to_i
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def execute(sql)
    connection.execute(sql)
  end

  def select_value(sql)
    connection.select_value(sql)
  end

  def insert_returning(sql)
    connection.execute("#{sql} RETURNING id").first.fetch("id").to_i
  end

  def reference_time
    @reference_time ||= Time.utc(2026, 9, 20, 12, 0, 0)
  end

  def q(value)
    connection.quote(value)
  end

  def digest(value)
    Digest::SHA256.digest(value)
  end

  def bytea(value)
    value.nil? ? "NULL" : "decode('#{value.unpack1("H*")}', 'hex')"
  end

  def insert_user(email_digest: nil, email_key: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO users (email_ciphertext, email_lookup_digest, email_digest_key_version, created_at, updated_at)
      VALUES (#{email_digest ? q("ciphertext") : "NULL"}, #{bytea(email_digest)}, #{email_key || "NULL"}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_external_identity(user_id:, subject:, provider: "google_oidc", key_version: 1, claims_version: 1, digest_override: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO external_identities
        (user_id, provider, provider_subject_ciphertext, provider_subject_digest, digest_key_version,
         claims_version, last_authenticated_at, created_at, updated_at)
      VALUES
        (#{user_id}, #{q(provider)}, #{q("ciphertext")}, #{bytea(digest_override || digest(subject))}, #{key_version},
         #{claims_version}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_session(user_id: nil, status: "active", abuse_level: 0, started_at: reference_time, expires_at: reference_time + 3600)
    insert_returning(<<~SQL.squish)
      INSERT INTO shopping_sessions
        (user_id, status, started_at, last_activity_at, expires_at, abuse_level, created_at, updated_at)
      VALUES
        (#{user_id || "NULL"}, #{q(status)}, #{q(started_at)}, #{q(started_at)}, #{q(expires_at)}, #{abuse_level}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_consent(session_id:, user_id: nil, kind: "ai_provider_disclosure", decision: "accepted", scope_json: "{}", scope_schema_version: 1, withdrawn_at: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO consent_records
        (shopping_session_id, user_id, consent_kind, policy_version, decision, scope_json,
         scope_schema_version, recorded_at, withdrawn_at, correlation_id, created_at, updated_at)
      VALUES
        (#{session_id}, #{user_id || "NULL"}, #{q(kind)}, 'v1', #{q(decision)}, #{q(scope_json)}::jsonb,
         #{scope_schema_version}, #{q(reference_time)}, #{withdrawn_at ? q(withdrawn_at) : "NULL"}, gen_random_uuid(), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_turnstile(session_id:, token: "token", token_digest: nil, expires_at: reference_time + 300, source_digest: nil, source_version: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO turnstile_verifications
        (shopping_session_id, token_digest, expected_action, validated_hostname, success,
         challenge_timestamp, validated_at, expires_at, source_key_digest, source_key_version,
         purge_after, created_at, updated_at)
      VALUES
        (#{session_id}, #{bytea(token_digest || digest(token))}, 'start_ai', 'example.test', true,
         #{q(reference_time - 10)}, #{q(reference_time)}, #{q(expires_at)}, #{bytea(source_digest)}, #{source_version || "NULL"},
         #{q(reference_time + 30.days)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_grant(session_id:, consent_id:, verification_id: nil, **options)
    insert_returning(grant_sql(session_id: session_id, consent_id: consent_id, verification_id: verification_id, **options))
  end

  def grant_sql(session_id:, consent_id:, verification_id: nil, token: "grant", token_digest: nil, status: "active", expires_at: reference_time + 3600, lock_version: 0)
    <<~SQL.squish
      INSERT INTO ai_access_grants
        (shopping_session_id, grant_token_digest, status, disclosure_consent_record_id,
         turnstile_verification_id, issued_at, expires_at, lock_version, created_at, updated_at)
      VALUES
        (#{session_id}, #{bytea(token_digest || digest(token))}, #{q(status)}, #{consent_id},
         #{verification_id || "NULL"}, #{q(reference_time)}, #{q(expires_at)}, #{lock_version}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_provider_session(grant_id:, session_id:, provider: "elevenlabs", status: "active", ref: "provider-session", ref_digest: :default, key_version: 1, ended_at: nil)
    insert_returning(provider_session_sql(
      grant_id: grant_id,
      session_id: session_id,
      provider: provider,
      status: status,
      ref: ref,
      ref_digest: ref_digest,
      key_version: key_version,
      ended_at: ended_at
    ))
  end

  def provider_session_sql(grant_id:, session_id:, provider: "elevenlabs", status: "active", ref: "provider-session", ref_digest: :default, key_version: 1, ended_at: nil)
    actual_digest = ref_digest == :default ? (ref && digest(ref)) : ref_digest
    <<~SQL.squish
      INSERT INTO agent_provider_sessions
        (ai_access_grant_id, shopping_session_id, provider, provider_session_ref_ciphertext,
         provider_session_ref_digest, digest_key_version, status, started_at, ended_at,
         created_at, updated_at)
      VALUES
        (#{grant_id}, #{session_id}, #{q(provider)}, #{ref ? q("ciphertext") : "NULL"},
         #{bytea(actual_digest)}, #{key_version || "NULL"}, #{q(status)}, #{q(reference_time)},
         #{ended_at ? q(ended_at) : "NULL"}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def assert_constraint(unique: false, foreign_key: false, &block)
    error = assert_raises(ActiveRecord::StatementInvalid, &block)
    assert_kind_of ActiveRecord::RecordNotUnique, error if unique
    if foreign_key
      postgres_error = error.cause
      assert(
        error.is_a?(ActiveRecord::InvalidForeignKey) ||
          postgres_error.is_a?(PG::ForeignKeyViolation) ||
          postgres_error.is_a?(PG::RestrictViolation),
        "Expected a foreign-key violation, got #{error.class}: #{error.message}"
      )
    end
    error
  end

  def concurrent_inserts(statements)
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = statements.map do |statement|
      Thread.new do
        raw = PG.connect(pg_connection_options)
        ready << true
        start.pop
        raw.exec(statement)
        results << :inserted
      rescue PG::Error => error
        results << error.class
      ensure
        raw&.close
      end
    end
    statements.size.times { ready.pop }
    statements.size.times { start << true }
    threads.each(&:join)
    statements.size.times.map { results.pop }
  end

  def pg_connection_options
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    {
      host: config[:host],
      port: config[:port],
      dbname: config[:database],
      user: config[:username],
      password: config[:password]
    }.compact
  end

  def timestamp_columns(table)
    connection.exec_query(<<~SQL.squish).to_a
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = #{q(table)}
        AND data_type LIKE 'timestamp%'
    SQL
  end

  def column_default(table, column)
    select_value(<<~SQL.squish)
      SELECT column_default
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = #{q(table)} AND column_name = #{q(column)}
    SQL
  end

  def truncate_identity_tables
    existing = TABLES.select { |table| connection.data_source_exists?(table) }
    execute("TRUNCATE TABLE #{existing.join(", ")} RESTART IDENTITY CASCADE") if existing.any?
  end
end
