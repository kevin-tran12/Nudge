class CreateCartAndCheckoutTables < ActiveRecord::Migration[8.1]
  def up
    create_carts
    create_cart_items
    create_cart_mutations
    create_checkout_validations
    create_checkout_validation_items
    create_freight_quotes
    create_checkout_intents
    install_triggers
  end

  def down
    remove_triggers
    drop_table :checkout_intents
    drop_table :freight_quotes
    drop_table :checkout_validation_items
    drop_table :checkout_validations
    drop_table :cart_mutations
    drop_table :cart_items
    drop_table :carts
  end

  private

  def create_carts
    create_table :carts do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :shopping_session_id, null: false
      t.bigint :user_id
      t.text :status, null: false, default: "active"
      t.column :currency, "character(3)", null: false
      t.integer :lock_version, null: false, default: 0
      t.datetime :last_activity_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps null: false
    end

    add_index :carts, :public_id, unique: true
    add_index :carts, :user_id
    add_index :carts,
      :shopping_session_id,
      unique: true,
      where: "status = 'active'",
      name: "index_carts_on_active_session"
    add_foreign_key :carts, :shopping_sessions, on_delete: :restrict
    add_foreign_key :carts, :users, on_delete: :nullify
    add_check_constraint :carts,
      "status IN ('active','converted','abandoned','expired')",
      name: "carts_status_check"
    add_check_constraint :carts, "currency ~ '^[A-Z]{3}$'", name: "carts_currency_check"
    add_check_constraint :carts, "lock_version >= 0", name: "carts_lock_version_check"
    add_check_constraint :carts, "expires_at >= last_activity_at", name: "carts_expiry_check"
  end

  def create_cart_items
    create_table :cart_items do |t|
      t.bigint :cart_id, null: false
      t.bigint :product_variant_id, null: false
      t.integer :quantity, null: false
      t.bigint :last_displayed_unit_amount_minor
      t.column :currency, "character(3)"
      t.bigint :price_observation_id
      t.integer :lock_version, null: false, default: 0
      t.datetime :added_at, null: false
      t.timestamps null: false
    end

    add_index :cart_items, :cart_id
    add_index :cart_items, :product_variant_id
    add_index :cart_items, :price_observation_id
    add_index :cart_items, [ :cart_id, :product_variant_id ], unique: true, name: "index_cart_items_on_cart_and_variant"
    add_foreign_key :cart_items, :carts, on_delete: :cascade
    add_foreign_key :cart_items, :product_variants, on_delete: :restrict
    add_foreign_key :cart_items, :price_observations, on_delete: :nullify
    add_check_constraint :cart_items, "quantity > 0", name: "cart_items_quantity_check"
    add_check_constraint :cart_items,
      "last_displayed_unit_amount_minor IS NULL OR last_displayed_unit_amount_minor >= 0",
      name: "cart_items_amount_check"
    add_check_constraint :cart_items,
      "(last_displayed_unit_amount_minor IS NULL) = (currency IS NULL)",
      name: "cart_items_amount_currency_pair_check"
    add_check_constraint :cart_items,
      "currency IS NULL OR currency ~ '^[A-Z]{3}$'",
      name: "cart_items_currency_check"
    add_check_constraint :cart_items, "lock_version >= 0", name: "cart_items_lock_version_check"
  end

  def create_cart_mutations
    create_table :cart_mutations do |t|
      t.bigint :cart_id, null: false
      t.uuid :client_mutation_id, null: false
      t.text :operation, null: false
      t.bigint :product_variant_id, null: false
      t.integer :requested_quantity
      t.integer :quantity_delta
      t.binary :request_hash, null: false
      t.text :status, null: false, default: "pending"
      t.jsonb :result_snapshot
      t.integer :result_schema_version, limit: 2
      t.text :error_code
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.timestamps null: false
    end

    add_index :cart_mutations, :cart_id
    add_index :cart_mutations, :product_variant_id
    add_index :cart_mutations, [ :cart_id, :client_mutation_id ], unique: true, name: "index_cart_mutations_on_cart_and_client_id"
    add_foreign_key :cart_mutations, :carts, on_delete: :cascade
    add_foreign_key :cart_mutations, :product_variants, on_delete: :restrict
    add_check_constraint :cart_mutations,
      "octet_length(request_hash) = 32",
      name: "cart_mutations_request_hash_check"
    add_check_constraint :cart_mutations,
      "NOT (requested_quantity IS NOT NULL AND quantity_delta IS NOT NULL)",
      name: "cart_mutations_quantity_exclusive_check"
    add_check_constraint :cart_mutations,
      "(result_snapshot IS NULL) = (result_schema_version IS NULL)",
      name: "cart_mutations_result_pair_check"
    add_check_constraint :cart_mutations,
      "result_schema_version IS NULL OR result_schema_version > 0",
      name: "cart_mutations_result_version_check"
    add_check_constraint :cart_mutations,
      "completed_at IS NULL OR completed_at >= started_at",
      name: "cart_mutations_completion_check"
  end

  def create_checkout_validations
    create_table :checkout_validations do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :cart_id, null: false
      t.text :status, null: false, default: "pending"
      t.text :failure_reason
      t.column :destination_country, "character(2)", null: false
      t.text :destination_region
      t.text :destination_ciphertext
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.datetime :expires_at, null: false
      t.text :total_policy_version, null: false
      t.text :margin_policy_version, null: false
      t.timestamps null: false
    end

    add_index :checkout_validations, :public_id, unique: true
    add_index :checkout_validations, :cart_id
    add_foreign_key :checkout_validations, :carts, on_delete: :restrict
    add_check_constraint :checkout_validations,
      "status IN ('pending','passed','failed','expired')",
      name: "checkout_validations_status_check"
    add_check_constraint :checkout_validations, "expires_at > started_at", name: "checkout_validations_expiry_check"
    add_check_constraint :checkout_validations,
      "completed_at IS NULL OR completed_at >= started_at",
      name: "checkout_validations_completion_check"
  end

  def create_checkout_validation_items
    create_table :checkout_validation_items do |t|
      t.bigint :checkout_validation_id, null: false
      t.bigint :product_variant_id, null: false
      t.integer :requested_quantity, null: false
      t.text :inventory_result, null: false
      t.bigint :supplier_amount_minor
      t.column :currency, "character(3)"
      t.text :freight_result, null: false
      t.text :destination_result, null: false
      t.text :margin_result, null: false
      t.text :overall_result, null: false
      t.bigint :price_observation_id
      t.bigint :inventory_observation_id
      t.datetime :evidence_observed_at, null: false
      t.timestamps null: false
    end

    add_index :checkout_validation_items, :product_variant_id
    add_index :checkout_validation_items, :price_observation_id
    add_index :checkout_validation_items, :inventory_observation_id
    add_index :checkout_validation_items,
      [ :checkout_validation_id, :product_variant_id ],
      unique: true,
      name: "index_checkout_validation_items_on_validation_and_variant"
    add_foreign_key :checkout_validation_items, :checkout_validations, on_delete: :cascade
    add_foreign_key :checkout_validation_items, :product_variants, on_delete: :restrict
    add_foreign_key :checkout_validation_items, :price_observations, on_delete: :nullify
    add_foreign_key :checkout_validation_items, :inventory_observations, on_delete: :nullify
    add_check_constraint :checkout_validation_items, "requested_quantity > 0", name: "checkout_validation_items_quantity_check"
    %w[inventory freight destination margin overall].each do |result_column|
      add_check_constraint :checkout_validation_items,
        "#{result_column}_result IN ('pass','fail','unknown')",
        name: "checkout_validation_items_#{result_column}_result_check"
    end
    add_check_constraint :checkout_validation_items,
      "(supplier_amount_minor IS NULL) = (currency IS NULL)",
      name: "checkout_validation_items_amount_currency_pair_check"
    add_check_constraint :checkout_validation_items,
      "supplier_amount_minor IS NULL OR supplier_amount_minor >= 0",
      name: "checkout_validation_items_amount_check"
    add_check_constraint :checkout_validation_items,
      "currency IS NULL OR currency ~ '^[A-Z]{3}$'",
      name: "checkout_validation_items_currency_check"
  end

  def create_freight_quotes
    create_table :freight_quotes do |t|
      t.bigint :checkout_validation_id, null: false
      t.bigint :supplier_id, null: false
      t.text :provider_ref_ciphertext
      t.binary :provider_ref_digest
      t.integer :digest_key_version, limit: 2
      t.text :warehouse_external_id, null: false
      t.text :logistics_id, null: false
      t.text :logistics_name, null: false
      t.bigint :amount_minor, null: false
      t.column :currency, "character(3)", null: false
      t.integer :delivery_min_days
      t.integer :delivery_max_days
      t.bigint :supplier_observation_id
      t.datetime :quoted_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps null: false
    end

    add_index :freight_quotes, :checkout_validation_id
    add_index :freight_quotes, :supplier_id
    add_index :freight_quotes, :supplier_observation_id
    add_foreign_key :freight_quotes, :checkout_validations, on_delete: :cascade
    add_foreign_key :freight_quotes, :suppliers, on_delete: :restrict
    add_foreign_key :freight_quotes, :supplier_observations, on_delete: :nullify
    add_check_constraint :freight_quotes, "amount_minor >= 0", name: "freight_quotes_amount_check"
    add_check_constraint :freight_quotes, "currency ~ '^[A-Z]{3}$'", name: "freight_quotes_currency_check"
    add_check_constraint :freight_quotes,
      "delivery_min_days IS NULL OR delivery_min_days >= 0",
      name: "freight_quotes_delivery_min_check"
    add_check_constraint :freight_quotes,
      "delivery_max_days IS NULL OR delivery_max_days >= 0",
      name: "freight_quotes_delivery_max_check"
    add_check_constraint :freight_quotes,
      "delivery_min_days IS NULL OR delivery_max_days IS NULL OR delivery_max_days >= delivery_min_days",
      name: "freight_quotes_delivery_range_check"
    add_check_constraint :freight_quotes, "expires_at > quoted_at", name: "freight_quotes_expiry_check"
    add_check_constraint :freight_quotes,
      "(provider_ref_ciphertext IS NULL) = (provider_ref_digest IS NULL) AND " \
        "(provider_ref_digest IS NULL) = (digest_key_version IS NULL)",
      name: "freight_quotes_provider_ref_pair_check"
    add_check_constraint :freight_quotes,
      "provider_ref_digest IS NULL OR octet_length(provider_ref_digest) = 32",
      name: "freight_quotes_provider_ref_digest_length_check"
    add_check_constraint :freight_quotes,
      "digest_key_version IS NULL OR digest_key_version > 0",
      name: "freight_quotes_digest_key_version_check"
  end

  def create_checkout_intents
    create_table :checkout_intents do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.text :execution_mode, null: false
      t.bigint :cart_id, null: false
      t.text :provider, null: false
      t.text :intent_key, null: false
      t.binary :request_hash, null: false
      t.text :status, null: false, default: "open"
      t.text :blocked_reason
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.datetime :expires_at, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps null: false
    end

    add_index :checkout_intents, :public_id, unique: true
    add_index :checkout_intents, :cart_id
    add_index :checkout_intents,
      [ :execution_mode, :cart_id, :provider, :intent_key ],
      unique: true,
      name: "index_checkout_intents_on_mode_cart_provider_key"
    add_index :checkout_intents, [ :id, :execution_mode ], unique: true, name: "index_checkout_intents_on_id_and_mode"
    add_index :checkout_intents,
      :expires_at,
      where: "status IN ('open','blocked')",
      name: "index_checkout_intents_on_expiry_open_blocked"
    add_foreign_key :checkout_intents, :carts, on_delete: :restrict
    add_check_constraint :checkout_intents,
      "execution_mode IN ('fixture','sandbox','live')",
      name: "checkout_intents_execution_mode_check"
    add_check_constraint :checkout_intents,
      "status IN ('open','blocked','converted','expired','cancelled')",
      name: "checkout_intents_status_check"
    add_check_constraint :checkout_intents, "octet_length(request_hash) = 32", name: "checkout_intents_request_hash_check"
    add_check_constraint :checkout_intents, "expires_at > started_at", name: "checkout_intents_expiry_check"
    add_check_constraint :checkout_intents,
      "(status = 'blocked') = (blocked_reason IS NOT NULL)",
      name: "checkout_intents_blocked_reason_check"
    add_check_constraint :checkout_intents,
      "(status IN ('converted','expired','cancelled')) = (completed_at IS NOT NULL)",
      name: "checkout_intents_completion_presence_check"
    add_check_constraint :checkout_intents,
      "completed_at IS NULL OR completed_at >= started_at",
      name: "checkout_intents_completion_check"
    add_check_constraint :checkout_intents, "lock_version >= 0", name: "checkout_intents_lock_version_check"
  end

  def install_triggers
    execute <<~SQL
      CREATE TRIGGER checkout_intents_execution_mode_immutable BEFORE UPDATE ON checkout_intents
        FOR EACH ROW EXECUTE FUNCTION public.nudge_prevent_execution_mode_change();
    SQL
  end

  def remove_triggers
    execute <<~SQL
      DROP TRIGGER IF EXISTS checkout_intents_execution_mode_immutable ON checkout_intents;
    SQL
  end
end
