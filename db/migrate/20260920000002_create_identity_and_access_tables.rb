class CreateIdentityAndAccessTables < ActiveRecord::Migration[8.1]
  def change
    create_users
    create_external_identities
    create_shopping_sessions
    create_consent_records
    create_turnstile_verifications
    create_ai_access_grants
    create_agent_provider_sessions
  end

  private

  def create_users
    create_table :users do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.text :status, null: false, default: "active"
      t.text :email_ciphertext
      t.binary :email_lookup_digest
      t.integer :email_digest_key_version, limit: 2
      t.text :locale
      t.text :region_code
      t.datetime :last_authenticated_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps null: false
    end

    add_index :users, :public_id, unique: true
    add_index :users, [ :email_digest_key_version, :email_lookup_digest ],
      unique: true,
      where: "email_lookup_digest IS NOT NULL",
      name: "index_users_on_email_lookup"
    add_check_constraint :users, "status IN ('active','disabled','deletion_pending')", name: "users_status_check"
    add_check_constraint :users,
      "(email_lookup_digest IS NULL) = (email_digest_key_version IS NULL)",
      name: "users_email_digest_pair_check"
    add_check_constraint :users,
      "email_lookup_digest IS NULL OR octet_length(email_lookup_digest) = 32",
      name: "users_email_digest_length_check"
    add_check_constraint :users,
      "email_digest_key_version IS NULL OR email_digest_key_version > 0",
      name: "users_email_digest_key_version_check"
    add_check_constraint :users, "lock_version >= 0", name: "users_lock_version_check"
  end

  def create_external_identities
    create_table :external_identities do |t|
      t.bigint :user_id, null: false
      t.text :provider, null: false
      t.text :provider_subject_ciphertext, null: false
      t.binary :provider_subject_digest, null: false
      t.integer :digest_key_version, limit: 2, null: false
      t.datetime :email_verified_at
      t.integer :claims_version, limit: 2, null: false
      t.datetime :last_authenticated_at, null: false
      t.uuid :encryption_context, null: false, default: -> { "gen_random_uuid()" }
      t.timestamps null: false
    end

    add_index :external_identities, :user_id
    add_index :external_identities, :encryption_context, unique: true
    add_index :external_identities,
      [ :provider, :digest_key_version, :provider_subject_digest ],
      unique: true,
      name: "index_external_identities_on_provider_subject"
    add_foreign_key :external_identities, :users, on_delete: :cascade
    add_check_constraint :external_identities, "provider = 'google_oidc'", name: "external_identities_provider_check"
    add_check_constraint :external_identities,
      "octet_length(provider_subject_digest) = 32",
      name: "external_identities_subject_digest_length_check"
    add_check_constraint :external_identities, "digest_key_version > 0", name: "external_identities_digest_key_version_check"
    add_check_constraint :external_identities, "claims_version > 0", name: "external_identities_claims_version_check"
  end

  def create_shopping_sessions
    create_table :shopping_sessions do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :user_id
      t.text :status, null: false, default: "active"
      t.datetime :started_at, null: false
      t.datetime :last_activity_at, null: false
      t.datetime :expires_at, null: false
      t.text :coarse_region_code
      t.integer :abuse_level, limit: 2, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.timestamps null: false
    end

    add_index :shopping_sessions, :public_id, unique: true
    add_index :shopping_sessions, [ :user_id, :status ]
    add_index :shopping_sessions, [ :status, :expires_at ]
    add_foreign_key :shopping_sessions, :users, on_delete: :nullify
    add_check_constraint :shopping_sessions,
      "status IN ('active','expired','blocked','closed')",
      name: "shopping_sessions_status_check"
    add_check_constraint :shopping_sessions, "abuse_level BETWEEN 0 AND 4", name: "shopping_sessions_abuse_level_check"
    add_check_constraint :shopping_sessions, "expires_at > started_at", name: "shopping_sessions_expiry_check"
    add_check_constraint :shopping_sessions, "lock_version >= 0", name: "shopping_sessions_lock_version_check"
  end

  def create_consent_records
    create_table :consent_records do |t|
      t.bigint :shopping_session_id, null: false
      t.bigint :user_id
      t.text :consent_kind, null: false
      t.text :policy_version, null: false
      t.text :decision, null: false
      t.jsonb :scope_json, null: false, default: {}
      t.integer :scope_schema_version, limit: 2, null: false
      t.datetime :recorded_at, null: false
      t.datetime :withdrawn_at
      t.uuid :correlation_id, null: false
      t.timestamps null: false
    end

    add_index :consent_records, :shopping_session_id
    add_index :consent_records, :user_id
    add_index :consent_records, :correlation_id
    add_index :consent_records, [ :id, :shopping_session_id ], unique: true
    add_index :consent_records,
      [ :shopping_session_id, :consent_kind, :policy_version ],
      unique: true,
      where: "withdrawn_at IS NULL",
      name: "index_consent_records_on_active_policy"
    add_foreign_key :consent_records, :shopping_sessions, on_delete: :restrict
    add_foreign_key :consent_records, :users, on_delete: :nullify
    add_check_constraint :consent_records,
      "consent_kind IN ('cookie_preferences','ai_provider_disclosure')",
      name: "consent_records_kind_check"
    add_check_constraint :consent_records,
      "decision IN ('accepted','rejected','customized')",
      name: "consent_records_decision_check"
    add_check_constraint :consent_records, "jsonb_typeof(scope_json) = 'object'", name: "consent_records_scope_object_check"
    add_check_constraint :consent_records, "scope_schema_version > 0", name: "consent_records_scope_version_check"
    add_check_constraint :consent_records,
      "withdrawn_at IS NULL OR withdrawn_at >= recorded_at",
      name: "consent_records_withdrawal_check"
  end

  def create_turnstile_verifications
    create_table :turnstile_verifications do |t|
      t.bigint :shopping_session_id, null: false
      t.binary :token_digest, null: false
      t.text :expected_action, null: false
      t.text :validated_hostname, null: false
      t.boolean :success, null: false
      t.text :failure_code
      t.datetime :challenge_timestamp, null: false
      t.datetime :validated_at, null: false
      t.datetime :expires_at, null: false
      t.binary :source_key_digest
      t.integer :source_key_version, limit: 2
      t.datetime :purge_after, null: false
      t.timestamps null: false
    end

    add_index :turnstile_verifications, :shopping_session_id
    add_index :turnstile_verifications, :token_digest, unique: true
    add_index :turnstile_verifications, :purge_after
    add_index :turnstile_verifications, [ :id, :shopping_session_id ], unique: true
    add_foreign_key :turnstile_verifications, :shopping_sessions, on_delete: :cascade
    add_check_constraint :turnstile_verifications,
      "octet_length(token_digest) = 32",
      name: "turnstile_verifications_token_digest_length_check"
    add_check_constraint :turnstile_verifications,
      "(source_key_digest IS NULL) = (source_key_version IS NULL)",
      name: "turnstile_verifications_source_key_pair_check"
    add_check_constraint :turnstile_verifications,
      "source_key_digest IS NULL OR octet_length(source_key_digest) = 32",
      name: "turnstile_verifications_source_key_length_check"
    add_check_constraint :turnstile_verifications,
      "source_key_version IS NULL OR source_key_version > 0",
      name: "turnstile_verifications_source_key_version_check"
    add_check_constraint :turnstile_verifications,
      "challenge_timestamp <= validated_at",
      name: "turnstile_verifications_challenge_time_check"
    add_check_constraint :turnstile_verifications,
      "expires_at > validated_at AND expires_at <= validated_at + interval '5 minutes'",
      name: "turnstile_verifications_expiry_check"
  end

  def create_ai_access_grants
    create_table :ai_access_grants do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :shopping_session_id, null: false
      t.binary :grant_token_digest, null: false
      t.text :status, null: false, default: "active"
      t.bigint :disclosure_consent_record_id, null: false
      t.bigint :turnstile_verification_id
      t.text :verification_reason_snapshot
      t.datetime :issued_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.text :revocation_reason_code
      t.integer :lock_version, null: false, default: 0
      t.timestamps null: false
    end

    add_index :ai_access_grants, :public_id, unique: true
    add_index :ai_access_grants, :grant_token_digest, unique: true
    add_index :ai_access_grants, :disclosure_consent_record_id
    add_index :ai_access_grants, :turnstile_verification_id, unique: true, where: "turnstile_verification_id IS NOT NULL"
    add_index :ai_access_grants, [ :id, :shopping_session_id ], unique: true
    add_index :ai_access_grants, :shopping_session_id, unique: true, where: "status = 'active'", name: "index_ai_access_grants_on_active_session"
    add_foreign_key :ai_access_grants, :shopping_sessions, on_delete: :restrict
    add_foreign_key :ai_access_grants,
      :consent_records,
      column: [ :disclosure_consent_record_id, :shopping_session_id ],
      primary_key: [ :id, :shopping_session_id ],
      on_delete: :restrict,
      name: "fk_ai_grants_consent_session"
    reversible do |direction|
      direction.up do
        execute <<~SQL
          ALTER TABLE ai_access_grants
          ADD CONSTRAINT fk_ai_grants_turnstile_session
          FOREIGN KEY (turnstile_verification_id, shopping_session_id)
          REFERENCES turnstile_verifications (id, shopping_session_id)
          ON DELETE SET NULL (turnstile_verification_id)
        SQL
      end
      direction.down do
        execute <<~SQL
          ALTER TABLE ai_access_grants
          DROP CONSTRAINT fk_ai_grants_turnstile_session
        SQL
      end
    end
    add_check_constraint :ai_access_grants,
      "octet_length(grant_token_digest) = 32",
      name: "ai_access_grants_token_digest_length_check"
    add_check_constraint :ai_access_grants,
      "status IN ('active','expired','revoked','terminated')",
      name: "ai_access_grants_status_check"
    add_check_constraint :ai_access_grants,
      "expires_at > issued_at AND expires_at <= issued_at + interval '60 minutes'",
      name: "ai_access_grants_expiry_check"
    add_check_constraint :ai_access_grants, "lock_version >= 0", name: "ai_access_grants_lock_version_check"
  end

  def create_agent_provider_sessions
    create_table :agent_provider_sessions do |t|
      t.bigint :ai_access_grant_id, null: false
      t.bigint :shopping_session_id, null: false
      t.text :provider, null: false
      t.text :provider_session_ref_ciphertext
      t.binary :provider_session_ref_digest
      t.integer :digest_key_version, limit: 2
      t.text :status, null: false
      t.datetime :started_at, null: false
      t.datetime :ended_at
      t.datetime :last_event_at
      t.text :termination_reason
      t.integer :lock_version, null: false, default: 0
      t.uuid :encryption_context, null: false, default: -> { "gen_random_uuid()" }
      t.timestamps null: false
    end

    add_index :agent_provider_sessions, [ :ai_access_grant_id, :shopping_session_id ]
    add_index :agent_provider_sessions, :encryption_context, unique: true
    add_index :agent_provider_sessions,
      [ :provider, :digest_key_version, :provider_session_ref_digest ],
      unique: true,
      where: "provider_session_ref_digest IS NOT NULL",
      name: "index_agent_provider_sessions_on_provider_ref"
    add_index :agent_provider_sessions,
      :shopping_session_id,
      unique: true,
      where: "status IN ('starting','active')",
      name: "index_agent_provider_sessions_on_active_session"
    add_foreign_key :agent_provider_sessions,
      :ai_access_grants,
      column: [ :ai_access_grant_id, :shopping_session_id ],
      primary_key: [ :id, :shopping_session_id ],
      on_delete: :restrict,
      name: "fk_provider_sessions_grant_session"
    add_check_constraint :agent_provider_sessions, "provider = 'elevenlabs'", name: "agent_provider_sessions_provider_check"
    add_check_constraint :agent_provider_sessions,
      "status IN ('starting','active','ended','terminated','failed')",
      name: "agent_provider_sessions_status_check"
    add_check_constraint :agent_provider_sessions,
      "(provider_session_ref_ciphertext IS NULL AND provider_session_ref_digest IS NULL AND digest_key_version IS NULL) OR " \
        "(provider_session_ref_ciphertext IS NOT NULL AND provider_session_ref_digest IS NOT NULL AND digest_key_version IS NOT NULL)",
      name: "agent_provider_sessions_ref_pair_check"
    add_check_constraint :agent_provider_sessions,
      "provider_session_ref_digest IS NULL OR octet_length(provider_session_ref_digest) = 32",
      name: "agent_provider_sessions_ref_digest_length_check"
    add_check_constraint :agent_provider_sessions,
      "digest_key_version IS NULL OR digest_key_version > 0",
      name: "agent_provider_sessions_digest_key_version_check"
    add_check_constraint :agent_provider_sessions,
      "ended_at IS NULL OR ended_at >= started_at",
      name: "agent_provider_sessions_end_time_check"
    add_check_constraint :agent_provider_sessions, "lock_version >= 0", name: "agent_provider_sessions_lock_version_check"
  end
end
