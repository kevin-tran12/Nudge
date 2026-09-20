require "test_helper"
require "digest"
require "pg"

class DatabaseShoppingDecisionsTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TABLES = %w[
    agent_tool_calls
    agent_runs
    recommendation_evidence
    eligibility_results
    recommendation_candidates
    recommendation_runs
    clarification_decisions
    requirements
    shopping_messages
  ].freeze

  CATALOG_TABLES = %w[
    inventory_observations price_observations product_facts fact_definitions
    catalog_media supplier_observations supplier_warehouses supplier_variants
    supplier_products product_variants product_categories products categories suppliers
  ].freeze

  IDENTITY_TABLES = %w[
    agent_provider_sessions ai_access_grants turnstile_verifications
    consent_records shopping_sessions external_identities users
  ].freeze

  setup { reset_database_rows }
  teardown { reset_database_rows }

  test "creates exactly the approved DB-06 shopping-decision and agent-record tables" do
    expected_columns = {
      "shopping_messages" => %w[id shopping_session_id ai_access_grant_id role source text_ciphertext redacted_text provider_message_ref_digest digest_key_version sequence occurred_at purge_after safety_status redaction_status created_at],
      "requirements" => %w[id public_id shopping_session_id requirement_key operator kind value_json value_schema_version source confidence importance needs_clarification status originating_message_id originating_tool_call_id supersedes_requirement_id confirmed_at created_at updated_at],
      "clarification_decisions" => %w[id shopping_session_id recommendation_run_id requirement_id candidate_reduction importance answerability interaction_cost computed_value policy_version reason_code selected_message_id skipped_reason created_at],
      "recommendation_runs" => %w[id public_id shopping_session_id requirement_set_hash search_policy_version status started_at completed_at query_limit candidate_limit result_summary result_schema_version no_result_reason history_influenced latency_ms cost_microunits lease_owner lease_token lease_expires_at purge_after created_at updated_at],
      "recommendation_candidates" => %w[id recommendation_run_id product_id product_variant_id retrieval_source retrieval_rank lexical_score semantic_score soft_score final_eligibility final_rank included reason_code created_at updated_at],
      "eligibility_results" => %w[id recommendation_candidate_id requirement_id outcome product_fact_id evaluator_version policy_version reason_code evaluated_at created_at],
      "recommendation_evidence" => %w[id recommendation_candidate_id product_fact_id price_observation_id inventory_observation_id supplier_observation_id freshness_at display_excerpt created_at],
      "agent_runs" => %w[id public_id shopping_session_id ai_access_grant_id agent_provider_session_id correlation_id status provider model_ref input_tokens output_tokens cost_microunits latency_ms started_at completed_at lease_owner lease_token lease_expires_at purge_after created_at updated_at],
      "agent_tool_calls" => %w[id agent_run_id sequence tool_name tool_version request_hash input_projection input_schema_version output_projection output_schema_version authorization_result idempotency_key status error_code started_at completed_at purge_after created_at updated_at]
    }
    expected_columns.each do |table, columns|
      assert connection.data_source_exists?(table), table
      assert_equal columns.sort, connection.columns(table).map(&:name).sort, table
    end
  end

  test "allows only one active requirement per session/key, supersedes cleanly, and bounds scores" do
    session_id = insert_session
    active_id = insert_requirement(session_id: session_id, key: "budget_max")

    assert_constraint(unique: true) { insert_requirement(session_id: session_id, key: "budget_max") }
    assert insert_requirement(session_id: session_id, key: "other_key")

    execute("UPDATE requirements SET status = 'superseded' WHERE id = #{active_id}")
    replacement_id = insert_requirement(session_id: session_id, key: "budget_max", supersedes: active_id)
    assert_operator replacement_id, :>, active_id

    assert_constraint(check: true) { execute("UPDATE requirements SET supersedes_requirement_id = id WHERE id = #{replacement_id}") }

    assert_constraint(check: true) { insert_requirement(session_id: session_id, key: "confidence-high", confidence: "1.5") }
    assert_constraint(check: true) { insert_requirement(session_id: session_id, key: "confidence-low", confidence: "-0.1") }
    assert_constraint(check: true) { insert_requirement(session_id: session_id, key: "importance-high", importance: "1.01") }
    assert insert_requirement(session_id: session_id, key: "confidence-boundary-one", confidence: "1")
    assert insert_requirement(session_id: session_id, key: "confidence-boundary-zero", confidence: "0")

    assert_constraint(check: true) { insert_requirement(session_id: session_id, key: "bad-kind", kind: "medium") }
    assert_constraint(check: true) { insert_requirement(session_id: session_id, key: "bad-source", source: "guessed") }
    assert_constraint(check: true) { insert_requirement(session_id: session_id, key: "bad-status", status: "archived") }
  end

  test "rejects duplicate message sequence numbers within a session and nulls the grant on delete" do
    session_id = insert_session
    grant_id = insert_grant(session_id: session_id)
    message_id = insert_message(session_id: session_id, sequence: 1, grant_id: grant_id)

    assert_constraint(unique: true) { insert_message(session_id: session_id, sequence: 1) }
    assert insert_message(session_id: session_id, sequence: 2)
    assert_constraint(check: true) { insert_message(session_id: session_id, sequence: 3, role: "narrator") }

    execute("DELETE FROM ai_access_grants WHERE id = #{grant_id}")
    assert_nil select_value("SELECT ai_access_grant_id FROM shopping_messages WHERE id = #{message_id}")
  end

  test "requires exactly one clarification decision outcome and bounds its input scores" do
    session_id = insert_session
    run_id = insert_recommendation_run(session_id: session_id)
    requirement_id = insert_requirement(session_id: session_id, key: "clarify-key")
    message_id = insert_message(session_id: session_id, sequence: 1)

    assert insert_clarification(session_id: session_id, run_id: run_id, requirement_id: requirement_id, selected_message_id: message_id, skipped_reason: nil)
    assert insert_clarification(session_id: session_id, run_id: run_id, requirement_id: requirement_id, selected_message_id: nil, skipped_reason: "low_value")
    assert insert_clarification(session_id: session_id, run_id: run_id, requirement_id: requirement_id, selected_message_id: nil, skipped_reason: nil)
    assert_constraint(check: true) do
      insert_clarification(session_id: session_id, run_id: run_id, requirement_id: requirement_id, selected_message_id: message_id, skipped_reason: "both_set")
    end
    assert_constraint(check: true) { insert_clarification(session_id: session_id, importance: "1.5") }
    assert_constraint(check: true) { insert_clarification(session_id: session_id, answerability: "-0.2") }

    execute("DELETE FROM requirements WHERE id = #{requirement_id}")
    assert_equal 3, select_value("SELECT count(*) FROM clarification_decisions").to_i
  end

  test "permits only one queued or running recommendation run per session under a genuine race" do
    session_id = insert_session
    results = concurrent_inserts([
      recommendation_run_sql(session_id: session_id, status: "queued"),
      recommendation_run_sql(session_id: session_id, status: "running")
    ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)
  end

  test "requires an explicit locked transition before a stale recommendation-run lease can be replaced" do
    session_id = insert_session
    stale_id = insert_recommendation_run(
      session_id: session_id,
      status: "running",
      lease_owner: "worker-a",
      lease_token: SecureRandom.uuid,
      lease_expires_at: reference_time - 60
    )

    assert_constraint(unique: true) { insert_recommendation_run(session_id: session_id, status: "queued") }

    connection.transaction do
      locked = select_value(<<~SQL.squish)
        SELECT id FROM recommendation_runs WHERE id = #{stale_id} AND lease_expires_at < CURRENT_TIMESTAMP FOR UPDATE
      SQL
      assert_equal stale_id, locked.to_i
      execute("UPDATE recommendation_runs SET status = 'failed', lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL WHERE id = #{stale_id}")
      recovered_id = insert_recommendation_run(session_id: session_id, status: "queued", lease_owner: "worker-b", lease_token: SecureRandom.uuid, lease_expires_at: reference_time + 60)
      assert_operator recovered_id, :>, stale_id
    end

    assert_equal "queued", select_value("SELECT status FROM recommendation_runs WHERE lease_owner = 'worker-b'")
  end

  test "pairs recommendation run lease columns and bounds limits and hash length" do
    session_id = insert_session

    assert_constraint(check: true) { insert_recommendation_run(session_id: session_id, lease_owner: "solo") }
    assert_constraint(check: true) { insert_recommendation_run(session_id: session_id, lease_token: SecureRandom.uuid) }
    assert_constraint(check: true) { insert_recommendation_run(session_id: session_id, query_limit: 0) }
    assert_constraint(check: true) { insert_recommendation_run(session_id: session_id, candidate_limit: -1) }
    assert_constraint(check: true) { insert_recommendation_run(session_id: session_id, hash: Digest::SHA256.digest("short")[0, 16]) }
  end

  test "enforces recommendation candidate uniqueness per run/variant with null-safe handling" do
    session_id = insert_session
    run_id = insert_recommendation_run(session_id: session_id)
    product_id = insert_product
    variant_id = insert_product_variant(product_id: product_id)

    insert_candidate(run_id: run_id, product_id: product_id)
    assert_constraint(unique: true) { insert_candidate(run_id: run_id, product_id: product_id) }

    insert_candidate(run_id: run_id, product_id: product_id, variant_id: variant_id)
    assert_constraint(unique: true) { insert_candidate(run_id: run_id, product_id: product_id, variant_id: variant_id) }

    assert_constraint(check: true) { insert_candidate(run_id: run_id, product_id: product_id, variant_id: nil, retrieval_rank: 0) }
    assert_constraint(check: true) { insert_candidate(run_id: run_id, product_id: product_id, variant_id: nil, eligibility: "maybe") }

    assert_constraint(foreign_key: true) { execute("DELETE FROM products WHERE id = #{product_id}") }
  end

  test "enforces a unique eligibility outcome per candidate/requirement and a valid outcome vocabulary" do
    session_id = insert_session
    run_id = insert_recommendation_run(session_id: session_id)
    product_id = insert_product
    candidate_id = insert_candidate(run_id: run_id, product_id: product_id)
    requirement_id = insert_requirement(session_id: session_id, key: "eligibility-key")

    insert_eligibility_result(candidate_id: candidate_id, requirement_id: requirement_id)
    assert_constraint(unique: true) { insert_eligibility_result(candidate_id: candidate_id, requirement_id: requirement_id) }
    assert_constraint(check: true) { insert_eligibility_result(candidate_id: candidate_id, requirement_id: requirement_id, outcome: "maybe") }

    assert_constraint(foreign_key: true) { execute("DELETE FROM requirements WHERE id = #{requirement_id}") }
    execute("DELETE FROM recommendation_candidates WHERE id = #{candidate_id}")
    assert_equal 0, select_value("SELECT count(*) FROM eligibility_results").to_i
  end

  test "requires recommendation evidence to reference exactly one subject" do
    session_id = insert_session
    run_id = insert_recommendation_run(session_id: session_id)
    product_id = insert_product
    candidate_id = insert_candidate(run_id: run_id, product_id: product_id)
    fact_id = insert_product_fact(product_id: product_id)
    price_id = insert_price_observation
    inventory_id = insert_inventory_observation
    observation_id = insert_supplier_observation

    assert_constraint(check: true) { insert_evidence(candidate_id: candidate_id) }
    assert_constraint(check: true) do
      insert_evidence(candidate_id: candidate_id, product_fact_id: fact_id, price_observation_id: price_id)
    end
    assert_constraint(check: true) do
      insert_evidence(candidate_id: candidate_id, price_observation_id: price_id, inventory_observation_id: inventory_id)
    end

    assert insert_evidence(candidate_id: candidate_id, product_fact_id: fact_id)
    assert insert_evidence(candidate_id: candidate_id, price_observation_id: price_id)
    assert insert_evidence(candidate_id: candidate_id, inventory_observation_id: inventory_id)
    assert insert_evidence(candidate_id: candidate_id, supplier_observation_id: observation_id)

    # product_facts is the only evidence subject whose base table permits a DELETE at all: price
    # observations, inventory observations, and supplier observations are each made unconditionally
    # immutable by DB-04 triggers (already-merged, not owned by this migration), so a DELETE there
    # always raises that trigger's check violation before any foreign key is ever evaluated. Prove
    # RESTRICT against product_facts directly, and prove the other three evidence foreign keys are
    # declared RESTRICT by reading their delete rule from the catalog instead.
    assert_constraint(foreign_key: true) { execute("DELETE FROM product_facts WHERE id = #{fact_id}") }
    %w[price_observations inventory_observations supplier_observations].each do |table|
      assert_equal "r", select_value(<<~SQL.squish), table
        SELECT confdeltype FROM pg_constraint
        WHERE conrelid = 'recommendation_evidence'::regclass
          AND confrelid = '#{table}'::regclass
          AND contype = 'f'
      SQL
    end

    execute("DELETE FROM recommendation_candidates WHERE id = #{candidate_id}")
    assert_equal 0, select_value("SELECT count(*) FROM recommendation_evidence").to_i
  end

  test "permits only one queued or running agent turn per session under a genuine race" do
    session_id = insert_session
    results = concurrent_inserts([
      agent_run_sql(session_id: session_id, status: "queued"),
      agent_run_sql(session_id: session_id, status: "running")
    ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)
  end

  test "requires an explicit locked transition before a stale agent-run lease can be replaced" do
    session_id = insert_session
    stale_id = insert_agent_run(
      session_id: session_id,
      status: "running",
      lease_owner: "worker-a",
      lease_token: SecureRandom.uuid,
      lease_expires_at: reference_time - 60
    )

    assert_constraint(unique: true) { insert_agent_run(session_id: session_id, status: "queued") }

    connection.transaction do
      locked = select_value(<<~SQL.squish)
        SELECT id FROM agent_runs WHERE id = #{stale_id} AND lease_expires_at < CURRENT_TIMESTAMP FOR UPDATE
      SQL
      assert_equal stale_id, locked.to_i
      execute("UPDATE agent_runs SET status = 'terminated', lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL WHERE id = #{stale_id}")
      recovered_id = insert_agent_run(session_id: session_id, status: "queued", lease_owner: "worker-b", lease_token: SecureRandom.uuid, lease_expires_at: reference_time + 60)
      assert_operator recovered_id, :>, stale_id
    end

    assert_equal "queued", select_value("SELECT status FROM agent_runs WHERE lease_owner = 'worker-b'")
  end

  test "denies an agent run bound to another session's grant or provider session" do
    session_a = insert_session
    session_b = insert_session
    grant_a = insert_grant(session_id: session_a)
    grant_b = insert_grant(session_id: session_b)
    provider_session_a = insert_provider_session(grant_id: grant_a, session_id: session_a)
    provider_session_b = insert_provider_session(grant_id: grant_b, session_id: session_b)

    assert insert_agent_run(session_id: session_a, grant_id: grant_a, provider_session_id: provider_session_a)

    # Each mismatch below targets a session with no active agent run yet, so the foreign-key
    # violation is not shadowed by the one-active-turn-per-session unique index (that index fires
    # before an AFTER-ROW foreign-key check on INSERT; its own race coverage is the next test).
    grant_mismatch_session = insert_session
    assert_constraint(foreign_key: true) { insert_agent_run(session_id: grant_mismatch_session, grant_id: grant_b) }

    provider_mismatch_session = insert_session
    provider_mismatch_grant = insert_grant(session_id: provider_mismatch_session)
    assert_constraint(foreign_key: true) do
      insert_agent_run(session_id: provider_mismatch_session, grant_id: provider_mismatch_grant, provider_session_id: provider_session_b)
    end

    assert_constraint(foreign_key: true) { insert_agent_run(session_id: session_b, grant_id: grant_a) }
  end

  test "enforces agent tool call sequence and idempotency key uniqueness, including under a genuine race" do
    session_id = insert_session
    run_id = insert_agent_run(session_id: session_id)

    insert_tool_call(run_id: run_id, sequence: 1, idempotency_key: "search-1")
    assert_constraint(unique: true) { insert_tool_call(run_id: run_id, sequence: 1, idempotency_key: "search-2") }
    assert_constraint(unique: true) { insert_tool_call(run_id: run_id, sequence: 2, idempotency_key: "search-1") }
    assert insert_tool_call(run_id: run_id, sequence: 2, idempotency_key: nil)
    assert insert_tool_call(run_id: run_id, sequence: 3, idempotency_key: nil)

    # A terminal status keeps this second run outside the one-active-turn-per-session
    # partial unique index (that constraint is verified on its own in the "genuine race"
    # test above), so this insert only needs to prove that idempotency-key scoping is
    # per agent_run rather than global.
    other_run_id = insert_agent_run(session_id: session_id, status: "succeeded")
    assert insert_tool_call(run_id: other_run_id, sequence: 1, idempotency_key: "search-1")

    results = concurrent_inserts([
      tool_call_sql(run_id: run_id, sequence: 10, idempotency_key: "race-key"),
      tool_call_sql(run_id: run_id, sequence: 11, idempotency_key: "race-key")
    ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)

    assert_constraint(check: true) { insert_tool_call(run_id: run_id, sequence: 20, hash: Digest::SHA256.digest("x")[0, 10]) }
  end

  test "cascades the recommendation subtree from its run and cascades tool calls from their agent run" do
    session_id = insert_session
    run_id = insert_recommendation_run(session_id: session_id)
    product_id = insert_product
    candidate_id = insert_candidate(run_id: run_id, product_id: product_id)
    requirement_id = insert_requirement(session_id: session_id, key: "cascade-key")
    insert_eligibility_result(candidate_id: candidate_id, requirement_id: requirement_id)
    fact_id = insert_product_fact(product_id: product_id)
    insert_evidence(candidate_id: candidate_id, product_fact_id: fact_id)

    agent_run_id = insert_agent_run(session_id: session_id)
    insert_tool_call(run_id: agent_run_id, sequence: 1)

    execute("DELETE FROM recommendation_runs WHERE id = #{run_id}")
    assert_equal 0, select_value("SELECT count(*) FROM recommendation_candidates").to_i
    assert_equal 0, select_value("SELECT count(*) FROM eligibility_results").to_i
    assert_equal 0, select_value("SELECT count(*) FROM recommendation_evidence").to_i

    execute("DELETE FROM agent_runs WHERE id = #{agent_run_id}")
    assert_equal 0, select_value("SELECT count(*) FROM agent_tool_calls").to_i

    execute("DELETE FROM shopping_sessions WHERE id = #{session_id}")
    %w[requirements shopping_messages recommendation_runs agent_runs clarification_decisions].each do |table|
      assert_equal 0, select_value("SELECT count(*) FROM #{table}").to_i, table
    end
  end

  private

  def connection = ActiveRecord::Base.connection

  def execute(sql) = connection.execute(sql)

  def select_value(sql) = connection.select_value(sql)

  def insert_returning(sql) = connection.execute("#{sql} RETURNING id").first.fetch("id").to_i

  def q(value) = connection.quote(value)

  def reference_time
    @reference_time ||= Time.utc(2026, 9, 20, 12, 0, 0)
  end

  def digest(value) = Digest::SHA256.digest(value)

  def bytea(value)
    value.nil? ? "NULL" : "decode('#{value.unpack1("H*")}', 'hex')"
  end

  def reset_database_rows
    all_tables = (TABLES + CATALOG_TABLES + IDENTITY_TABLES).select { |table| connection.data_source_exists?(table) }
    execute("TRUNCATE TABLE #{all_tables.join(', ')} RESTART IDENTITY CASCADE") if all_tables.any?
  end

  def assert_constraint(unique: false, foreign_key: false, check: false, &block)
    error = assert_raises(ActiveRecord::StatementInvalid, &block)
    assert_kind_of ActiveRecord::RecordNotUnique, error if unique
    if foreign_key
      cause = error.cause
      assert(
        error.is_a?(ActiveRecord::InvalidForeignKey) ||
          cause.is_a?(PG::ForeignKeyViolation) ||
          cause.is_a?(PG::RestrictViolation),
        "Expected a foreign-key violation, got #{error.class}: #{error.message}"
      )
    end
    if check
      assert_kind_of PG::CheckViolation, error.cause, "Expected a check violation, got #{error.class}: #{error.message}"
    end
    error
  end

  # -- Identity chain -------------------------------------------------

  def insert_session
    insert_returning(<<~SQL.squish)
      INSERT INTO shopping_sessions (status, started_at, last_activity_at, expires_at, created_at, updated_at)
      VALUES ('active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '1 hour', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_consent(session_id:)
    insert_returning(<<~SQL.squish)
      INSERT INTO consent_records
        (shopping_session_id, consent_kind, policy_version, decision, scope_json, scope_schema_version, recorded_at, correlation_id, created_at, updated_at)
      VALUES
        (#{session_id}, 'ai_provider_disclosure', 'v1', 'accepted', '{}'::jsonb, 1, CURRENT_TIMESTAMP, gen_random_uuid(), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_grant(session_id:)
    consent_id = insert_consent(session_id: session_id)
    insert_returning(<<~SQL.squish)
      INSERT INTO ai_access_grants
        (shopping_session_id, grant_token_digest, status, disclosure_consent_record_id, issued_at, expires_at, lock_version, created_at, updated_at)
      VALUES
        (#{session_id}, #{bytea(digest("grant-#{SecureRandom.hex(8)}"))}, 'active', #{consent_id}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '30 minutes', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_provider_session(grant_id:, session_id:)
    ref = "provider-session-#{SecureRandom.hex(8)}"
    insert_returning(<<~SQL.squish)
      INSERT INTO agent_provider_sessions
        (ai_access_grant_id, shopping_session_id, provider, provider_session_ref_ciphertext, provider_session_ref_digest, digest_key_version, status, started_at, created_at, updated_at)
      VALUES
        (#{grant_id}, #{session_id}, 'elevenlabs', #{q("ciphertext")}, #{bytea(digest(ref))}, 1, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  # -- Catalog chain (for evidence exclusivity) ------------------------

  def insert_supplier
    key = "supplier-#{SecureRandom.hex(6)}"
    insert_returning(<<~SQL.squish)
      INSERT INTO suppliers (key, display_name, adapter_version, api_version, status, created_at, updated_at)
      VALUES (#{q(key)}, 'Supplier', 'v1', 'v1', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_product
    insert_returning(<<~SQL.squish)
      INSERT INTO products (status, title, description, lock_version, created_at, updated_at)
      VALUES ('draft', 'Product', '', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_product_variant(product_id:)
    insert_returning(<<~SQL.squish)
      INSERT INTO product_variants (product_id, title, option_summary, option_schema_version, status, lock_version, created_at, updated_at)
      VALUES (#{product_id}, 'Variant', '{}', 1, 'active', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_supplier_product(supplier_id:, product_id:)
    external_id = "external-product-#{SecureRandom.hex(6)}"
    insert_returning(<<~SQL.squish)
      INSERT INTO supplier_products (supplier_id, product_id, external_product_id, status, first_seen_at, last_seen_at, adapter_version, created_at, updated_at)
      VALUES (#{supplier_id}, #{product_id}, #{q(external_id)}, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, 'v1', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_supplier_variant(supplier_id:, supplier_product_id:, product_variant_id:)
    external_id = "external-variant-#{SecureRandom.hex(6)}"
    insert_returning(<<~SQL.squish)
      INSERT INTO supplier_variants (supplier_id, product_variant_id, supplier_product_id, external_variant_id, status, first_seen_at, last_seen_at, created_at, updated_at)
      VALUES (#{supplier_id}, #{product_variant_id}, #{supplier_product_id}, #{q(external_id)}, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_warehouse(supplier_id:)
    external_id = "warehouse-#{SecureRandom.hex(6)}"
    insert_returning(<<~SQL.squish)
      INSERT INTO supplier_warehouses (supplier_id, external_warehouse_id, status, first_seen_at, last_seen_at, created_at, updated_at)
      VALUES (#{supplier_id}, #{q(external_id)}, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_supplier_observation(supplier_id: nil, kind: "product", external_id: nil)
    supplier_id ||= insert_supplier
    external_id ||= "external-#{SecureRandom.hex(6)}"
    insert_returning(<<~SQL.squish)
      INSERT INTO supplier_observations
        (supplier_id, resource_kind, external_resource_id, endpoint_key, adapter_version, payload_schema_version,
         payload_json, payload_sha256, observed_at, received_at, purge_after, created_at)
      VALUES
        (#{supplier_id}, #{q(kind)}, #{q(external_id)}, 'catalog', 'v1', 1, '{"ok":true}'::jsonb,
         decode(repeat('ab', 32), 'hex'), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '30 days', CURRENT_TIMESTAMP)
    SQL
  end

  def insert_fact_definition
    key = "weight-#{SecureRandom.hex(6)}"
    insert_returning(<<~SQL.squish)
      INSERT INTO fact_definitions
        (key, label, data_type, unit_dimension, canonical_unit, allowed_operators, allowed_operators_schema_version,
         hard_eligibility_supported, version, status, created_at, updated_at)
      VALUES
        (#{q(key)}, 'Weight', 'measurement', 'mass', 'g', '["eq"]', 1, false, 1, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_product_fact(product_id:)
    definition_id = insert_fact_definition
    observation_id = insert_supplier_observation
    insert_returning(<<~SQL.squish)
      INSERT INTO product_facts
        (product_id, fact_definition_id, decimal_value, canonical_unit, source_kind, supplier_observation_id, observed_at, status, created_at, updated_at)
      VALUES
        (#{product_id}, #{definition_id}, 12.5, 'g', 'supplier', #{observation_id}, CURRENT_TIMESTAMP, 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_price_observation
    supplier_id = insert_supplier
    product_id = insert_product
    supplier_product_id = insert_supplier_product(supplier_id: supplier_id, product_id: product_id)
    variant_id = insert_product_variant(product_id: product_id)
    supplier_variant_id = insert_supplier_variant(supplier_id: supplier_id, supplier_product_id: supplier_product_id, product_variant_id: variant_id)
    observation_id = insert_supplier_observation(supplier_id: supplier_id, kind: "stock", external_id: "price-#{SecureRandom.hex(6)}")
    insert_returning(<<~SQL.squish)
      INSERT INTO price_observations (supplier_id, supplier_variant_id, supplier_observation_id, amount_minor, currency, price_kind, observed_at)
      VALUES (#{supplier_id}, #{supplier_variant_id}, #{observation_id}, 1000, 'USD', 'retail', CURRENT_TIMESTAMP)
    SQL
  end

  def insert_inventory_observation
    supplier_id = insert_supplier
    product_id = insert_product
    supplier_product_id = insert_supplier_product(supplier_id: supplier_id, product_id: product_id)
    variant_id = insert_product_variant(product_id: product_id)
    supplier_variant_id = insert_supplier_variant(supplier_id: supplier_id, supplier_product_id: supplier_product_id, product_variant_id: variant_id)
    warehouse_id = insert_warehouse(supplier_id: supplier_id)
    observation_id = insert_supplier_observation(supplier_id: supplier_id, kind: "stock", external_id: "inventory-#{SecureRandom.hex(6)}")
    insert_returning(<<~SQL.squish)
      INSERT INTO inventory_observations (supplier_id, supplier_variant_id, supplier_warehouse_id, supplier_observation_id, total_quantity, observed_at)
      VALUES (#{supplier_id}, #{supplier_variant_id}, #{warehouse_id}, #{observation_id}, 5, CURRENT_TIMESTAMP)
    SQL
  end

  # -- Slice 07 rows ----------------------------------------------------

  def insert_message(session_id:, sequence:, grant_id: nil, role: "user")
    insert_returning(<<~SQL.squish)
      INSERT INTO shopping_messages
        (shopping_session_id, ai_access_grant_id, role, source, sequence, occurred_at, purge_after, created_at)
      VALUES
        (#{session_id}, #{grant_id || "NULL"}, #{q(role)}, 'web', #{sequence}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '30 days', CURRENT_TIMESTAMP)
    SQL
  end

  def insert_requirement(session_id:, key:, status: "active", confidence: "0.8", importance: "0.8", kind: "hard", source: "user_explicit", supersedes: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO requirements
        (shopping_session_id, requirement_key, operator, kind, value_json, value_schema_version, source, confidence,
         importance, status, supersedes_requirement_id, created_at, updated_at)
      VALUES
        (#{session_id}, #{q(key)}, 'eq', #{q(kind)}, '{}'::jsonb, 1, #{q(source)}, #{confidence}, #{importance}, #{q(status)},
         #{supersedes || "NULL"}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_clarification(session_id:, run_id: nil, requirement_id: nil, selected_message_id: nil, skipped_reason: nil, importance: "0.5", answerability: "0.5")
    insert_returning(<<~SQL.squish)
      INSERT INTO clarification_decisions
        (shopping_session_id, recommendation_run_id, requirement_id, candidate_reduction, importance, answerability,
         interaction_cost, computed_value, policy_version, reason_code, selected_message_id, skipped_reason, created_at)
      VALUES
        (#{session_id}, #{run_id || "NULL"}, #{requirement_id || "NULL"}, 0.5, #{importance}, #{answerability}, 0.5, 1.0,
         'v1', 'ask', #{selected_message_id || "NULL"}, #{skipped_reason ? q(skipped_reason) : "NULL"}, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_recommendation_run(session_id:, **options)
    insert_returning(recommendation_run_sql(session_id: session_id, **options))
  end

  def recommendation_run_sql(session_id:, status: "queued", lease_owner: nil, lease_token: nil, lease_expires_at: nil, query_limit: 20, candidate_limit: 50, hash: nil)
    lease_owner_sql = lease_owner ? q(lease_owner) : "NULL"
    lease_token_sql = lease_token ? q(lease_token) : "NULL"
    lease_expires_sql = lease_expires_at ? q(lease_expires_at) : "NULL"
    <<~SQL.squish
      INSERT INTO recommendation_runs
        (shopping_session_id, requirement_set_hash, search_policy_version, status, query_limit, candidate_limit,
         result_summary, result_schema_version, lease_owner, lease_token, lease_expires_at, purge_after, created_at, updated_at)
      VALUES
        (#{session_id}, #{bytea(hash || digest("requirements-#{SecureRandom.hex(6)}"))}, 'v1', #{q(status)}, #{query_limit}, #{candidate_limit},
         '{}'::jsonb, 1, #{lease_owner_sql}, #{lease_token_sql}, #{lease_expires_sql}, CURRENT_TIMESTAMP + interval '180 days', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_candidate(run_id:, product_id:, variant_id: nil, retrieval_rank: 1, eligibility: "pass")
    insert_returning(<<~SQL.squish)
      INSERT INTO recommendation_candidates
        (recommendation_run_id, product_id, product_variant_id, retrieval_source, retrieval_rank, final_eligibility, included, reason_code, created_at, updated_at)
      VALUES
        (#{run_id}, #{product_id}, #{variant_id || "NULL"}, 'lexical', #{retrieval_rank}, #{q(eligibility)}, true, 'match', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_eligibility_result(candidate_id:, requirement_id:, outcome: "pass")
    insert_returning(<<~SQL.squish)
      INSERT INTO eligibility_results
        (recommendation_candidate_id, requirement_id, outcome, evaluator_version, policy_version, reason_code, evaluated_at, created_at)
      VALUES
        (#{candidate_id}, #{requirement_id}, #{q(outcome)}, 'v1', 'v1', 'match', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_evidence(candidate_id:, product_fact_id: nil, price_observation_id: nil, inventory_observation_id: nil, supplier_observation_id: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO recommendation_evidence
        (recommendation_candidate_id, product_fact_id, price_observation_id, inventory_observation_id, supplier_observation_id, freshness_at, created_at)
      VALUES
        (#{candidate_id}, #{product_fact_id || "NULL"}, #{price_observation_id || "NULL"}, #{inventory_observation_id || "NULL"}, #{supplier_observation_id || "NULL"}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_agent_run(session_id:, **options)
    insert_returning(agent_run_sql(session_id: session_id, **options))
  end

  def agent_run_sql(session_id:, status: "queued", grant_id: nil, provider_session_id: nil, lease_owner: nil, lease_token: nil, lease_expires_at: nil)
    lease_owner_sql = lease_owner ? q(lease_owner) : "NULL"
    lease_token_sql = lease_token ? q(lease_token) : "NULL"
    lease_expires_sql = lease_expires_at ? q(lease_expires_at) : "NULL"
    <<~SQL.squish
      INSERT INTO agent_runs
        (shopping_session_id, ai_access_grant_id, agent_provider_session_id, correlation_id, status, provider,
         lease_owner, lease_token, lease_expires_at, purge_after, created_at, updated_at)
      VALUES
        (#{session_id}, #{grant_id || "NULL"}, #{provider_session_id || "NULL"}, gen_random_uuid(), #{q(status)}, 'elevenlabs',
         #{lease_owner_sql}, #{lease_token_sql}, #{lease_expires_sql}, CURRENT_TIMESTAMP + interval '90 days', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_tool_call(run_id:, sequence:, idempotency_key: nil, hash: nil)
    insert_returning(tool_call_sql(run_id: run_id, sequence: sequence, idempotency_key: idempotency_key, hash: hash))
  end

  def tool_call_sql(run_id:, sequence:, idempotency_key: nil, hash: nil)
    <<~SQL.squish
      INSERT INTO agent_tool_calls
        (agent_run_id, sequence, tool_name, tool_version, request_hash, input_projection, input_schema_version,
         authorization_result, idempotency_key, status, started_at, purge_after, created_at, updated_at)
      VALUES
        (#{run_id}, #{sequence}, 'search_catalog', 'v1', #{bytea(hash || digest("call-#{SecureRandom.hex(6)}"))}, '{}'::jsonb, 1,
         'authorized', #{idempotency_key ? q(idempotency_key) : "NULL"}, 'succeeded', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '90 days', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
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
    { host: config[:host], port: config[:port], dbname: config[:database], user: config[:username], password: config[:password] }.compact
  end
end
