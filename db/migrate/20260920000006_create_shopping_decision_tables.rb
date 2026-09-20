class CreateShoppingDecisionTables < ActiveRecord::Migration[8.1]
  def up
    create_shopping_messages
    add_agent_provider_sessions_composite_key
    create_agent_runs
    create_agent_tool_calls
    create_requirements
    create_recommendation_runs
    create_clarification_decisions
    create_recommendation_candidates
    create_eligibility_results
    create_recommendation_evidence
  end

  def down
    drop_table :recommendation_evidence
    drop_table :eligibility_results
    drop_table :recommendation_candidates
    drop_table :clarification_decisions
    drop_table :recommendation_runs
    drop_table :requirements
    drop_table :agent_tool_calls
    drop_table :agent_runs
    remove_agent_provider_sessions_composite_key
    drop_table :shopping_messages
  end

  private

  def create_shopping_messages
    create_table :shopping_messages do |t|
      t.bigint :shopping_session_id, null: false
      t.bigint :ai_access_grant_id
      t.text :role, null: false
      t.text :source, null: false
      t.text :text_ciphertext
      t.text :redacted_text
      t.binary :provider_message_ref_digest
      t.integer :digest_key_version, limit: 2
      t.bigint :sequence, null: false
      t.datetime :occurred_at, null: false
      t.datetime :purge_after, null: false
      t.text :safety_status, null: false, default: "unchecked"
      t.text :redaction_status, null: false, default: "pending"
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :shopping_messages, [ :shopping_session_id, :sequence ], unique: true, name: "index_shopping_messages_on_session_sequence"
    add_index :shopping_messages, :ai_access_grant_id
    add_index :shopping_messages, :purge_after
    add_foreign_key :shopping_messages, :shopping_sessions, on_delete: :cascade
    add_foreign_key :shopping_messages, :ai_access_grants, on_delete: :nullify
    add_check_constraint :shopping_messages, "role IN ('user','agent','system_event')", name: "shopping_messages_role_check"
    add_check_constraint :shopping_messages, "sequence > 0", name: "shopping_messages_sequence_check"
    add_check_constraint :shopping_messages,
      "(provider_message_ref_digest IS NULL) = (digest_key_version IS NULL)",
      name: "shopping_messages_digest_pair_check"
    add_check_constraint :shopping_messages,
      "provider_message_ref_digest IS NULL OR octet_length(provider_message_ref_digest) = 32",
      name: "shopping_messages_digest_length_check"
    add_check_constraint :shopping_messages,
      "digest_key_version IS NULL OR digest_key_version > 0",
      name: "shopping_messages_digest_key_version_check"
    add_check_constraint :shopping_messages, "purge_after >= occurred_at", name: "shopping_messages_purge_deadline_check"
  end

  def add_agent_provider_sessions_composite_key
    add_index :agent_provider_sessions, [ :id, :shopping_session_id ], unique: true, name: "index_agent_provider_sessions_on_id_and_session"
  end

  def remove_agent_provider_sessions_composite_key
    remove_index :agent_provider_sessions, name: "index_agent_provider_sessions_on_id_and_session"
  end

  def create_agent_runs
    create_table :agent_runs do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :shopping_session_id, null: false
      t.bigint :ai_access_grant_id
      t.bigint :agent_provider_session_id
      t.uuid :correlation_id, null: false
      t.text :status, null: false, default: "queued"
      t.text :provider, null: false
      t.text :model_ref
      t.integer :input_tokens
      t.integer :output_tokens
      t.bigint :cost_microunits
      t.integer :latency_ms
      t.datetime :started_at
      t.datetime :completed_at
      t.text :lease_owner
      t.uuid :lease_token
      t.datetime :lease_expires_at
      t.datetime :purge_after, null: false
      t.timestamps null: false
    end

    add_index :agent_runs, :public_id, unique: true
    add_index :agent_runs, :correlation_id, unique: true
    add_index :agent_runs, [ :ai_access_grant_id, :shopping_session_id ], name: "index_agent_runs_on_grant_and_session"
    add_index :agent_runs, [ :agent_provider_session_id, :shopping_session_id ], name: "index_agent_runs_on_provider_session_and_session"
    add_index :agent_runs, :shopping_session_id, unique: true, where: "status IN ('queued','running')", name: "index_agent_runs_on_active_session"
    add_index :agent_runs, :purge_after
    add_foreign_key :agent_runs, :shopping_sessions, on_delete: :cascade

    execute <<~SQL
      ALTER TABLE agent_runs
      ADD CONSTRAINT fk_agent_runs_grant_session
      FOREIGN KEY (ai_access_grant_id, shopping_session_id)
      REFERENCES ai_access_grants (id, shopping_session_id)
      ON DELETE SET NULL (ai_access_grant_id)
    SQL
    execute <<~SQL
      ALTER TABLE agent_runs
      ADD CONSTRAINT fk_agent_runs_provider_session
      FOREIGN KEY (agent_provider_session_id, shopping_session_id)
      REFERENCES agent_provider_sessions (id, shopping_session_id)
      ON DELETE SET NULL (agent_provider_session_id)
    SQL

    add_check_constraint :agent_runs,
      "status IN ('queued','running','succeeded','failed','cancelled','terminated')",
      name: "agent_runs_status_check"
    add_check_constraint :agent_runs, "input_tokens IS NULL OR input_tokens >= 0", name: "agent_runs_input_tokens_check"
    add_check_constraint :agent_runs, "output_tokens IS NULL OR output_tokens >= 0", name: "agent_runs_output_tokens_check"
    add_check_constraint :agent_runs, "cost_microunits IS NULL OR cost_microunits >= 0", name: "agent_runs_cost_check"
    add_check_constraint :agent_runs, "latency_ms IS NULL OR latency_ms >= 0", name: "agent_runs_latency_check"
    add_check_constraint :agent_runs,
      "(lease_owner IS NULL AND lease_token IS NULL AND lease_expires_at IS NULL) OR " \
        "(lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)",
      name: "agent_runs_lease_pair_check"
    add_check_constraint :agent_runs,
      "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at",
      name: "agent_runs_completion_check"
  end

  def create_agent_tool_calls
    create_table :agent_tool_calls do |t|
      t.bigint :agent_run_id, null: false
      t.bigint :sequence, null: false
      t.text :tool_name, null: false
      t.text :tool_version, null: false
      t.binary :request_hash, null: false
      t.jsonb :input_projection, null: false, default: {}
      t.integer :input_schema_version, limit: 2, null: false
      t.jsonb :output_projection
      t.integer :output_schema_version, limit: 2
      t.text :authorization_result, null: false
      t.text :idempotency_key
      t.text :status, null: false
      t.text :error_code
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.datetime :purge_after, null: false
      t.timestamps null: false
    end

    add_index :agent_tool_calls, [ :agent_run_id, :sequence ], unique: true, name: "index_agent_tool_calls_on_run_sequence"
    add_index :agent_tool_calls,
      [ :agent_run_id, :idempotency_key ],
      unique: true,
      where: "idempotency_key IS NOT NULL",
      name: "index_agent_tool_calls_on_run_idempotency"
    add_index :agent_tool_calls, :purge_after
    add_foreign_key :agent_tool_calls, :agent_runs, on_delete: :cascade
    add_check_constraint :agent_tool_calls, "sequence > 0", name: "agent_tool_calls_sequence_check"
    add_check_constraint :agent_tool_calls, "octet_length(request_hash) = 32", name: "agent_tool_calls_request_hash_check"
    add_check_constraint :agent_tool_calls, "jsonb_typeof(input_projection) = 'object'", name: "agent_tool_calls_input_object_check"
    add_check_constraint :agent_tool_calls, "input_schema_version > 0", name: "agent_tool_calls_input_version_check"
    add_check_constraint :agent_tool_calls,
      "output_projection IS NULL OR jsonb_typeof(output_projection) = 'object'",
      name: "agent_tool_calls_output_object_check"
    add_check_constraint :agent_tool_calls,
      "(output_projection IS NULL) = (output_schema_version IS NULL)",
      name: "agent_tool_calls_output_pair_check"
    add_check_constraint :agent_tool_calls,
      "output_schema_version IS NULL OR output_schema_version > 0",
      name: "agent_tool_calls_output_version_check"
    add_check_constraint :agent_tool_calls,
      "completed_at IS NULL OR completed_at >= started_at",
      name: "agent_tool_calls_completion_check"
  end

  def create_requirements
    create_table :requirements do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :shopping_session_id, null: false
      t.text :requirement_key, null: false
      t.text :operator, null: false
      t.text :kind, null: false
      t.jsonb :value_json, null: false
      t.integer :value_schema_version, limit: 2, null: false
      t.text :source, null: false
      t.decimal :confidence, precision: 8, scale: 6, null: false
      t.decimal :importance, precision: 8, scale: 6, null: false
      t.boolean :needs_clarification, null: false, default: false
      t.text :status, null: false, default: "active"
      t.bigint :originating_message_id
      t.bigint :originating_tool_call_id
      t.bigint :supersedes_requirement_id
      t.datetime :confirmed_at
      t.timestamps null: false
    end

    add_index :requirements, :public_id, unique: true
    add_index :requirements, :originating_message_id
    add_index :requirements, :originating_tool_call_id
    add_index :requirements, :supersedes_requirement_id
    add_index :requirements,
      [ :shopping_session_id, :requirement_key ],
      unique: true,
      where: "status = 'active'",
      name: "index_requirements_on_active_session_key"
    add_foreign_key :requirements, :shopping_sessions, on_delete: :cascade
    add_foreign_key :requirements, :shopping_messages, column: :originating_message_id, on_delete: :nullify
    add_foreign_key :requirements, :agent_tool_calls, column: :originating_tool_call_id, on_delete: :nullify
    add_foreign_key :requirements, :requirements, column: :supersedes_requirement_id, on_delete: :restrict
    add_check_constraint :requirements, "kind IN ('hard','soft')", name: "requirements_kind_check"
    add_check_constraint :requirements,
      "source IN ('user_explicit','user_inferred','system_derived','history_soft')",
      name: "requirements_source_check"
    add_check_constraint :requirements, "status IN ('active','rejected','superseded')", name: "requirements_status_check"
    add_check_constraint :requirements, "jsonb_typeof(value_json) = 'object'", name: "requirements_value_json_object_check"
    add_check_constraint :requirements, "value_schema_version > 0", name: "requirements_value_schema_version_check"
    add_check_constraint :requirements, "confidence BETWEEN 0 AND 1", name: "requirements_confidence_check"
    add_check_constraint :requirements, "importance BETWEEN 0 AND 1", name: "requirements_importance_check"
    add_check_constraint :requirements,
      "supersedes_requirement_id IS NULL OR supersedes_requirement_id <> id",
      name: "requirements_not_self_superseding_check"
  end

  def create_recommendation_runs
    create_table :recommendation_runs do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :shopping_session_id, null: false
      t.binary :requirement_set_hash, null: false
      t.text :search_policy_version, null: false
      t.text :status, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :query_limit, null: false
      t.integer :candidate_limit, null: false
      t.jsonb :result_summary, null: false, default: {}
      t.integer :result_schema_version, limit: 2, null: false
      t.text :no_result_reason
      t.boolean :history_influenced, null: false, default: false
      t.integer :latency_ms
      t.bigint :cost_microunits
      t.text :lease_owner
      t.uuid :lease_token
      t.datetime :lease_expires_at
      t.datetime :purge_after, null: false
      t.timestamps null: false
    end

    add_index :recommendation_runs, :public_id, unique: true
    add_index :recommendation_runs,
      :shopping_session_id,
      unique: true,
      where: "status IN ('queued','running')",
      name: "index_recommendation_runs_on_active_session"
    add_index :recommendation_runs, :purge_after
    add_foreign_key :recommendation_runs, :shopping_sessions, on_delete: :cascade
    add_check_constraint :recommendation_runs, "octet_length(requirement_set_hash) = 32", name: "recommendation_runs_hash_length_check"
    add_check_constraint :recommendation_runs,
      "status IN ('queued','running','succeeded','no_result','failed','cancelled')",
      name: "recommendation_runs_status_check"
    add_check_constraint :recommendation_runs, "query_limit > 0", name: "recommendation_runs_query_limit_check"
    add_check_constraint :recommendation_runs, "candidate_limit > 0", name: "recommendation_runs_candidate_limit_check"
    add_check_constraint :recommendation_runs, "jsonb_typeof(result_summary) = 'object'", name: "recommendation_runs_result_object_check"
    add_check_constraint :recommendation_runs, "result_schema_version > 0", name: "recommendation_runs_result_version_check"
    add_check_constraint :recommendation_runs, "latency_ms IS NULL OR latency_ms >= 0", name: "recommendation_runs_latency_check"
    add_check_constraint :recommendation_runs, "cost_microunits IS NULL OR cost_microunits >= 0", name: "recommendation_runs_cost_check"
    add_check_constraint :recommendation_runs,
      "(lease_owner IS NULL AND lease_token IS NULL AND lease_expires_at IS NULL) OR " \
        "(lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)",
      name: "recommendation_runs_lease_pair_check"
    add_check_constraint :recommendation_runs,
      "completed_at IS NULL OR started_at IS NULL OR completed_at >= started_at",
      name: "recommendation_runs_completion_check"
  end

  def create_clarification_decisions
    create_table :clarification_decisions do |t|
      t.bigint :shopping_session_id, null: false
      t.bigint :recommendation_run_id
      t.bigint :requirement_id
      t.decimal :candidate_reduction, precision: 8, scale: 6, null: false
      t.decimal :importance, precision: 8, scale: 6, null: false
      t.decimal :answerability, precision: 8, scale: 6, null: false
      t.decimal :interaction_cost, precision: 8, scale: 6, null: false
      t.decimal :computed_value, precision: 12, scale: 6, null: false
      t.text :policy_version, null: false
      t.text :reason_code, null: false
      t.bigint :selected_message_id
      t.text :skipped_reason
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :clarification_decisions, :shopping_session_id
    add_index :clarification_decisions, :recommendation_run_id
    add_index :clarification_decisions, :requirement_id
    add_index :clarification_decisions, :selected_message_id
    add_foreign_key :clarification_decisions, :shopping_sessions, on_delete: :cascade
    add_foreign_key :clarification_decisions, :recommendation_runs, on_delete: :nullify
    add_foreign_key :clarification_decisions, :requirements, on_delete: :nullify
    add_foreign_key :clarification_decisions, :shopping_messages, column: :selected_message_id, on_delete: :nullify
    add_check_constraint :clarification_decisions, "candidate_reduction BETWEEN 0 AND 1", name: "clarification_decisions_candidate_reduction_check"
    add_check_constraint :clarification_decisions, "importance BETWEEN 0 AND 1", name: "clarification_decisions_importance_check"
    add_check_constraint :clarification_decisions, "answerability BETWEEN 0 AND 1", name: "clarification_decisions_answerability_check"
    add_check_constraint :clarification_decisions, "interaction_cost BETWEEN 0 AND 1", name: "clarification_decisions_interaction_cost_check"
    add_check_constraint :clarification_decisions,
      "selected_message_id IS NULL OR skipped_reason IS NULL",
      name: "clarification_decisions_selection_pair_check"
  end

  def create_recommendation_candidates
    create_table :recommendation_candidates do |t|
      t.bigint :recommendation_run_id, null: false
      t.bigint :product_id, null: false
      t.bigint :product_variant_id
      t.text :retrieval_source, null: false
      t.integer :retrieval_rank, null: false
      t.decimal :lexical_score, precision: 12, scale: 6
      t.decimal :semantic_score, precision: 12, scale: 6
      t.decimal :soft_score, precision: 12, scale: 6
      t.text :final_eligibility, null: false
      t.integer :final_rank
      t.boolean :included, null: false, default: false
      t.text :reason_code, null: false
      t.timestamps null: false
    end

    add_index :recommendation_candidates, :recommendation_run_id
    add_index :recommendation_candidates, :product_id
    add_index :recommendation_candidates, :product_variant_id
    add_index :recommendation_candidates,
      "recommendation_run_id, product_id, COALESCE(product_variant_id, 0)",
      unique: true,
      name: "index_recommendation_candidates_unique_variant"
    add_foreign_key :recommendation_candidates, :recommendation_runs, on_delete: :cascade
    add_foreign_key :recommendation_candidates, :products, on_delete: :restrict
    add_foreign_key :recommendation_candidates, :product_variants, on_delete: :restrict
    add_check_constraint :recommendation_candidates, "retrieval_rank > 0", name: "recommendation_candidates_retrieval_rank_check"
    add_check_constraint :recommendation_candidates, "final_rank IS NULL OR final_rank > 0", name: "recommendation_candidates_final_rank_check"
    add_check_constraint :recommendation_candidates,
      "final_eligibility IN ('pass','fail','unknown')",
      name: "recommendation_candidates_eligibility_check"
  end

  def create_eligibility_results
    create_table :eligibility_results do |t|
      t.bigint :recommendation_candidate_id, null: false
      t.bigint :requirement_id, null: false
      t.text :outcome, null: false
      t.bigint :product_fact_id
      t.text :evaluator_version, null: false
      t.text :policy_version, null: false
      t.text :reason_code, null: false
      t.datetime :evaluated_at, null: false
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :eligibility_results,
      [ :recommendation_candidate_id, :requirement_id ],
      unique: true,
      name: "index_eligibility_results_unique_candidate_requirement"
    add_index :eligibility_results, :requirement_id
    add_index :eligibility_results, :product_fact_id
    add_foreign_key :eligibility_results, :recommendation_candidates, on_delete: :cascade
    add_foreign_key :eligibility_results, :requirements, on_delete: :restrict
    add_foreign_key :eligibility_results, :product_facts, on_delete: :restrict
    add_check_constraint :eligibility_results, "outcome IN ('pass','fail','unknown')", name: "eligibility_results_outcome_check"
  end

  def create_recommendation_evidence
    create_table :recommendation_evidence do |t|
      t.bigint :recommendation_candidate_id, null: false
      t.bigint :product_fact_id
      t.bigint :price_observation_id
      t.bigint :inventory_observation_id
      t.bigint :supplier_observation_id
      t.datetime :freshness_at, null: false
      t.text :display_excerpt
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :recommendation_evidence, :recommendation_candidate_id
    add_index :recommendation_evidence, :product_fact_id
    add_index :recommendation_evidence, :price_observation_id
    add_index :recommendation_evidence, :inventory_observation_id
    add_index :recommendation_evidence, :supplier_observation_id
    add_foreign_key :recommendation_evidence, :recommendation_candidates, on_delete: :cascade
    add_foreign_key :recommendation_evidence, :product_facts, on_delete: :restrict
    add_foreign_key :recommendation_evidence, :price_observations, on_delete: :restrict
    add_foreign_key :recommendation_evidence, :inventory_observations, on_delete: :restrict
    add_foreign_key :recommendation_evidence, :supplier_observations, on_delete: :restrict
    add_check_constraint :recommendation_evidence,
      "num_nonnulls(product_fact_id,price_observation_id,inventory_observation_id,supplier_observation_id) = 1",
      name: "recommendation_evidence_subject_check"
  end
end
