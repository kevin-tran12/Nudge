class CreateCatalogEvidenceAndSyncTables < ActiveRecord::Migration[8.1]
  def up
    add_supplier_scope_parent_keys
    create_supplier_observations
    create_catalog_media
    create_fact_definitions
    create_product_facts
    create_price_observations
    create_inventory_observations
    create_sync_runs
    create_sync_checkpoints
    create_supplier_subscriptions
    install_trigger_functions
    install_triggers
    add_latest_observation_constraints
  end

  def down
    remove_latest_observation_constraints
    remove_triggers
    remove_trigger_functions
    drop_table :supplier_subscriptions
    drop_table :sync_checkpoints
    drop_table :sync_runs
    drop_table :inventory_observations
    drop_table :price_observations
    drop_table :product_facts
    drop_table :fact_definitions
    drop_table :catalog_media
    drop_table :supplier_observations
    remove_supplier_scope_parent_keys
  end

  private

  def add_supplier_scope_parent_keys
    add_index :supplier_variants, %i[id supplier_id], unique: true, name: "index_supplier_variants_on_id_and_supplier_id"
    add_index :supplier_warehouses, %i[id supplier_id], unique: true, name: "index_supplier_warehouses_on_id_and_supplier_id"
  end

  def remove_supplier_scope_parent_keys
    remove_index :supplier_warehouses, name: "index_supplier_warehouses_on_id_and_supplier_id"
    remove_index :supplier_variants, name: "index_supplier_variants_on_id_and_supplier_id"
  end

  def create_supplier_observations
    create_table :supplier_observations do |t|
      t.bigint :supplier_id, null: false
      t.text :resource_kind, null: false
      t.text :external_resource_id, null: false
      t.text :provider_request_id
      t.text :endpoint_key, null: false
      t.text :adapter_version, null: false
      t.integer :payload_schema_version, limit: 2, null: false
      t.text :payload_ciphertext
      t.jsonb :payload_json
      t.binary :payload_sha256, null: false
      t.uuid :encryption_context, null: false, default: -> { "gen_random_uuid()" }
      t.datetime :observed_at, null: false
      t.datetime :received_at, null: false
      t.text :normalization_status, null: false, default: "pending"
      t.text :normalization_error_code
      t.datetime :purge_after, null: false
      t.datetime :purged_at
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :supplier_observations, :supplier_id
    add_index :supplier_observations, %i[id supplier_id], unique: true
    add_index :supplier_observations, :encryption_context, unique: true
    add_index :supplier_observations, %i[supplier_id resource_kind external_resource_id observed_at id], order: { observed_at: :desc, id: :desc }, name: "index_supplier_observations_resource_chronology"
    add_index :supplier_observations, %i[normalization_status received_at id], where: "purged_at IS NULL AND normalization_status IN ('pending','failed')", name: "index_supplier_observations_normalization_queue"
    add_index :supplier_observations, %i[purge_after id], where: "purged_at IS NULL", name: "index_supplier_observations_purge_queue"
    add_foreign_key :supplier_observations, :suppliers, on_delete: :restrict
    add_check_constraint :supplier_observations, "payload_schema_version > 0", name: "supplier_observations_payload_version_check"
    add_check_constraint :supplier_observations, "octet_length(payload_sha256) = 32", name: "supplier_observations_hash_check"
    add_check_constraint :supplier_observations, "payload_json IS NULL OR jsonb_typeof(payload_json) = 'object'", name: "supplier_observations_payload_object_check"
    add_check_constraint :supplier_observations, "purge_after >= received_at", name: "supplier_observations_purge_deadline_check"
    add_check_constraint :supplier_observations, <<~SQL.squish, name: "supplier_observations_payload_lifecycle_check"
      (purged_at IS NULL AND num_nonnulls(payload_ciphertext,payload_json) = 1) OR
      (purged_at IS NOT NULL AND payload_ciphertext IS NULL AND payload_json IS NULL AND purged_at >= purge_after)
    SQL
    add_check_constraint :supplier_observations, "normalization_status IN ('pending','normalized','failed')", name: "supplier_observations_normalization_status_check"
    add_check_constraint :supplier_observations, "(normalization_status = 'failed') = (normalization_error_code IS NOT NULL)", name: "supplier_observations_normalization_error_check"
  end

  def create_catalog_media
    create_table :catalog_media do |t|
      t.bigint :product_id
      t.bigint :product_variant_id
      t.bigint :supplier_observation_id
      t.text :kind, null: false
      t.text :original_url_ciphertext
      t.uuid :encryption_context, null: false, default: -> { "gen_random_uuid()" }
      t.text :sanitized_url
      t.text :object_key
      t.text :mime_type
      t.integer :width
      t.integer :height
      t.binary :checksum
      t.integer :position, null: false, default: 0
      t.text :status, null: false
      t.datetime :observed_at
      t.datetime :verified_at
      t.timestamps null: false
    end
    add_index :catalog_media, %i[product_id position id], where: "product_id IS NOT NULL", name: "index_catalog_media_product_position"
    add_index :catalog_media, %i[product_variant_id position id], where: "product_variant_id IS NOT NULL", name: "index_catalog_media_variant_position"
    add_index :catalog_media, :supplier_observation_id
    add_index :catalog_media, :encryption_context, unique: true
    add_foreign_key :catalog_media, :products, on_delete: :cascade
    add_foreign_key :catalog_media, :product_variants, on_delete: :cascade
    add_foreign_key :catalog_media, :supplier_observations, on_delete: :nullify
    add_check_constraint :catalog_media, "num_nonnulls(product_id,product_variant_id) = 1", name: "catalog_media_subject_check"
    add_check_constraint :catalog_media, "kind IN ('image','video')", name: "catalog_media_kind_check"
    add_check_constraint :catalog_media, "width IS NULL OR width >= 0", name: "catalog_media_width_check"
    add_check_constraint :catalog_media, "height IS NULL OR height >= 0", name: "catalog_media_height_check"
    add_check_constraint :catalog_media, "position >= 0", name: "catalog_media_position_check"
    add_check_constraint :catalog_media, "checksum IS NULL OR octet_length(checksum) = 32", name: "catalog_media_checksum_check"
  end

  def create_fact_definitions
    create_table :fact_definitions do |t|
      t.text :key, null: false
      t.text :label, null: false
      t.text :description
      t.text :data_type, null: false
      t.text :unit_dimension
      t.text :canonical_unit
      t.jsonb :allowed_operators, null: false
      t.integer :allowed_operators_schema_version, limit: 2, null: false
      t.jsonb :allowed_values_schema
      t.integer :allowed_values_schema_version, limit: 2
      t.boolean :hard_eligibility_supported, null: false, default: false
      t.integer :version, null: false
      t.text :status, null: false
      t.timestamps null: false
    end
    add_index :fact_definitions, :key, unique: true
    add_check_constraint :fact_definitions, "data_type IN ('boolean','integer','decimal','text','enum','measurement','json')", name: "fact_definitions_type_check"
    add_check_constraint :fact_definitions, "allowed_operators_schema_version > 0 AND version > 0", name: "fact_definitions_versions_check"
    add_check_constraint :fact_definitions, <<~SQL.squish, name: "fact_definitions_measurement_check"
      (data_type = 'measurement' AND nullif(btrim(unit_dimension),'') IS NOT NULL AND nullif(btrim(canonical_unit),'') IS NOT NULL) OR
      (data_type <> 'measurement' AND unit_dimension IS NULL AND canonical_unit IS NULL)
    SQL
    add_check_constraint :fact_definitions, <<~SQL.squish, name: "fact_definitions_allowed_values_pair_check"
      (data_type = 'enum' AND allowed_values_schema IS NOT NULL AND allowed_values_schema_version IS NOT NULL AND allowed_values_schema_version > 0) OR
      (data_type <> 'enum' AND allowed_values_schema IS NULL AND allowed_values_schema_version IS NULL)
    SQL
  end

  def create_product_facts
    create_table :product_facts do |t|
      t.bigint :product_id
      t.bigint :product_variant_id
      t.bigint :fact_definition_id, null: false
      t.boolean :boolean_value
      t.bigint :integer_value
      t.decimal :decimal_value, precision: 20, scale: 6
      t.text :text_value
      t.jsonb :json_value
      t.integer :value_schema_version, limit: 2
      t.text :canonical_unit
      t.text :source_kind, null: false
      t.bigint :supplier_observation_id
      t.decimal :confidence, precision: 8, scale: 6
      t.text :inference_version
      t.datetime :observed_at, null: false
      t.datetime :valid_from
      t.datetime :valid_until
      t.text :status, null: false
      t.bigint :supersedes_product_fact_id
      t.timestamps null: false
    end
    add_index :product_facts, :product_id
    add_index :product_facts, :product_variant_id
    add_index :product_facts, :fact_definition_id
    add_index :product_facts, :supplier_observation_id
    add_index :product_facts, :supersedes_product_fact_id
    %w[boolean integer decimal text].each do |kind|
      column = "#{kind}_value"
      add_index :product_facts, [ :fact_definition_id, column, :product_id, :product_variant_id, :id ], where: "status = 'active' AND #{column} IS NOT NULL", name: "index_product_facts_active_#{kind}"
    end
    add_foreign_key :product_facts, :products, on_delete: :cascade
    add_foreign_key :product_facts, :product_variants, on_delete: :cascade
    add_foreign_key :product_facts, :fact_definitions, on_delete: :restrict
    add_foreign_key :product_facts, :supplier_observations, on_delete: :restrict
    add_foreign_key :product_facts, :product_facts, column: :supersedes_product_fact_id, on_delete: :restrict
    add_check_constraint :product_facts, "num_nonnulls(product_id,product_variant_id) = 1", name: "product_facts_subject_check"
    add_check_constraint :product_facts, "num_nonnulls(boolean_value,integer_value,decimal_value,text_value,json_value) = 1", name: "product_facts_value_check"
    add_check_constraint :product_facts, "source_kind IN ('supplier','normalized','inferred','manual')", name: "product_facts_source_check"
    add_check_constraint :product_facts, "status IN ('active','superseded','rejected')", name: "product_facts_status_check"
    add_check_constraint :product_facts, "decimal_value IS NULL OR decimal_value NOT IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)", name: "product_facts_decimal_finite_check"
    add_check_constraint :product_facts, "confidence IS NULL OR (confidence NOT IN ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) AND confidence BETWEEN 0 AND 1)", name: "product_facts_confidence_check"
    add_check_constraint :product_facts, "text_value IS NULL OR octet_length(text_value) <= 1024", name: "product_facts_text_bound_check"
    add_check_constraint :product_facts, "json_value IS NULL OR (jsonb_typeof(json_value) IN ('object','array') AND value_schema_version IS NOT NULL AND value_schema_version > 0)", name: "product_facts_json_check"
    add_check_constraint :product_facts, "json_value IS NOT NULL OR value_schema_version IS NULL", name: "product_facts_value_version_check"
    add_check_constraint :product_facts, "source_kind = 'manual' OR supplier_observation_id IS NOT NULL", name: "product_facts_evidence_check"
    add_check_constraint :product_facts, "(source_kind = 'inferred' AND nullif(btrim(inference_version),'') IS NOT NULL AND confidence IS NOT NULL) OR (source_kind <> 'inferred' AND inference_version IS NULL)", name: "product_facts_inference_check"
    add_check_constraint :product_facts, "valid_until IS NULL OR valid_from IS NULL OR valid_until >= valid_from", name: "product_facts_validity_check"
    add_check_constraint :product_facts, "supersedes_product_fact_id IS NULL OR supersedes_product_fact_id <> id", name: "product_facts_not_self_superseding_check"
  end

  def create_price_observations
    create_table :price_observations do |t|
      t.bigint :supplier_id, null: false
      t.bigint :supplier_variant_id, null: false
      t.bigint :supplier_observation_id, null: false
      t.bigint :amount_minor, null: false
      t.column :currency, "character(3)", null: false
      t.text :price_kind, null: false
      t.integer :quantity_tier
      t.datetime :observed_at, null: false
      t.datetime :valid_until
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :price_observations, %i[supplier_variant_id supplier_id]
    add_index :price_observations, :supplier_id
    add_index :price_observations, %i[supplier_observation_id supplier_id]
    add_index :price_observations, %i[supplier_variant_id price_kind currency observed_at id], order: { observed_at: :desc, id: :desc }, name: "index_price_observations_current"
    add_foreign_key :price_observations, :suppliers, on_delete: :restrict
    add_foreign_key :price_observations, :supplier_variants, column: %i[supplier_variant_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, name: "fk_price_observations_variant_supplier"
    add_foreign_key :price_observations, :supplier_observations, column: %i[supplier_observation_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, name: "fk_price_observations_source_supplier"
    add_check_constraint :price_observations, "amount_minor >= 0", name: "price_observations_amount_check"
    add_check_constraint :price_observations, "currency ~ '^[A-Z]{3}$'", name: "price_observations_currency_check"
    add_check_constraint :price_observations, "quantity_tier IS NULL OR quantity_tier > 0", name: "price_observations_tier_check"
    add_check_constraint :price_observations, "valid_until IS NULL OR valid_until >= observed_at", name: "price_observations_validity_check"
  end

  def create_inventory_observations
    create_table :inventory_observations do |t|
      t.bigint :supplier_id, null: false
      t.bigint :supplier_variant_id, null: false
      t.bigint :supplier_warehouse_id, null: false
      t.bigint :supplier_observation_id, null: false
      t.bigint :total_quantity
      t.bigint :cj_quantity
      t.bigint :factory_quantity
      t.text :verification_state
      t.datetime :observed_at, null: false
      t.datetime :valid_until
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :inventory_observations, %i[supplier_variant_id supplier_warehouse_id supplier_observation_id], unique: true, name: "index_inventory_observations_unique_source"
    add_index :inventory_observations, %i[supplier_variant_id supplier_id]
    add_index :inventory_observations, :supplier_id
    add_index :inventory_observations, %i[supplier_warehouse_id supplier_id]
    add_index :inventory_observations, %i[supplier_observation_id supplier_id]
    add_index :inventory_observations, %i[supplier_variant_id supplier_warehouse_id observed_at id], order: { observed_at: :desc, id: :desc }, name: "index_inventory_observations_current"
    add_foreign_key :inventory_observations, :suppliers, on_delete: :restrict
    add_foreign_key :inventory_observations, :supplier_variants, column: %i[supplier_variant_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, name: "fk_inventory_observations_variant_supplier"
    add_foreign_key :inventory_observations, :supplier_warehouses, column: %i[supplier_warehouse_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, name: "fk_inventory_observations_warehouse_supplier"
    add_foreign_key :inventory_observations, :supplier_observations, column: %i[supplier_observation_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, name: "fk_inventory_observations_source_supplier"
    add_check_constraint :inventory_observations, "num_nonnulls(total_quantity,cj_quantity,factory_quantity) >= 1", name: "inventory_observations_quantity_present_check"
    add_check_constraint :inventory_observations, "(total_quantity IS NULL OR total_quantity >= 0) AND (cj_quantity IS NULL OR cj_quantity >= 0) AND (factory_quantity IS NULL OR factory_quantity >= 0)", name: "inventory_observations_quantities_check"
    add_check_constraint :inventory_observations, "valid_until IS NULL OR valid_until >= observed_at", name: "inventory_observations_validity_check"
  end

  def create_sync_runs
    create_table :sync_runs do |t|
      t.uuid :public_id, null: false, default: -> { "gen_random_uuid()" }
      t.bigint :supplier_id, null: false
      t.text :mode, null: false
      t.text :resource_kind, null: false
      t.text :scope_key, null: false
      t.jsonb :scope_json, null: false, default: {}
      t.integer :scope_schema_version, limit: 2, null: false
      t.text :adapter_version, null: false
      t.text :status, null: false, default: "pending"
      t.bigint :points_consumed, null: false, default: 0
      t.bigint :seen_count, null: false, default: 0
      t.bigint :created_count, null: false, default: 0
      t.bigint :updated_count, null: false, default: 0
      t.bigint :error_count, null: false, default: 0
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error_code
      t.timestamps null: false
    end
    add_index :sync_runs, :public_id, unique: true
    add_index :sync_runs, :supplier_id
    add_index :sync_runs, %i[supplier_id resource_kind scope_key created_at id], order: { created_at: :desc, id: :desc }, name: "index_sync_runs_scope_chronology"
    add_foreign_key :sync_runs, :suppliers, on_delete: :restrict
    add_check_constraint :sync_runs, "mode IN ('fixture','verify','record','live')", name: "sync_runs_mode_check"
    add_check_constraint :sync_runs, "status IN ('pending','running','succeeded','failed','cancelled')", name: "sync_runs_status_check"
    add_check_constraint :sync_runs, "jsonb_typeof(scope_json) = 'object' AND scope_schema_version > 0", name: "sync_runs_scope_check"
    add_check_constraint :sync_runs, "points_consumed >= 0 AND seen_count >= 0 AND created_count >= 0 AND updated_count >= 0 AND error_count >= 0", name: "sync_runs_counts_check"
    add_check_constraint :sync_runs, "completed_at IS NULL OR (started_at IS NOT NULL AND completed_at >= started_at)", name: "sync_runs_completion_check"
  end

  def create_sync_checkpoints
    create_table :sync_checkpoints do |t|
      t.bigint :sync_run_id, null: false
      t.text :checkpoint_key, null: false
      t.text :cursor
      t.integer :page_number
      t.jsonb :state_json, null: false, default: {}
      t.integer :state_schema_version, limit: 2, null: false
      t.timestamps null: false
    end
    add_index :sync_checkpoints, %i[sync_run_id checkpoint_key], unique: true
    add_foreign_key :sync_checkpoints, :sync_runs, on_delete: :cascade
    add_check_constraint :sync_checkpoints, "page_number IS NULL OR page_number > 0", name: "sync_checkpoints_page_check"
    add_check_constraint :sync_checkpoints, "jsonb_typeof(state_json) = 'object' AND state_schema_version > 0", name: "sync_checkpoints_state_check"
  end

  def create_supplier_subscriptions
    create_table :supplier_subscriptions do |t|
      t.bigint :supplier_id, null: false
      t.bigint :supplier_product_id, null: false
      t.text :topic, null: false
      t.text :external_ref_ciphertext
      t.binary :external_ref_digest
      t.integer :digest_key_version, limit: 2
      t.uuid :encryption_context, null: false, default: -> { "gen_random_uuid()" }
      t.text :status, null: false, default: "requested"
      t.datetime :requested_at, null: false
      t.datetime :confirmed_at
      t.datetime :last_verified_at
      t.datetime :closed_at
      t.text :close_reason
      t.integer :retry_count, null: false, default: 0
      t.datetime :next_retry_at
      t.timestamps null: false
    end
    add_index :supplier_subscriptions, %i[supplier_id supplier_product_id topic], unique: true, name: "index_supplier_subscriptions_logical"
    add_index :supplier_subscriptions, %i[supplier_product_id supplier_id]
    add_index :supplier_subscriptions, %i[supplier_id topic digest_key_version external_ref_digest], unique: true, where: "external_ref_digest IS NOT NULL", name: "index_supplier_subscriptions_provider_ref"
    add_index :supplier_subscriptions, :encryption_context, unique: true
    add_index :supplier_subscriptions, %i[next_retry_at id], where: "next_retry_at IS NOT NULL AND closed_at IS NULL", name: "index_supplier_subscriptions_retry"
    add_foreign_key :supplier_subscriptions, :suppliers, on_delete: :restrict
    add_foreign_key :supplier_subscriptions, :supplier_products, column: %i[supplier_product_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, name: "fk_supplier_subscriptions_product_supplier"
    add_check_constraint :supplier_subscriptions, "num_nonnulls(external_ref_ciphertext,external_ref_digest,digest_key_version) IN (0,3)", name: "supplier_subscriptions_external_ref_pair_check"
    add_check_constraint :supplier_subscriptions, "external_ref_digest IS NULL OR octet_length(external_ref_digest) = 32", name: "supplier_subscriptions_digest_check"
    add_check_constraint :supplier_subscriptions, "digest_key_version IS NULL OR digest_key_version > 0", name: "supplier_subscriptions_digest_version_check"
    add_check_constraint :supplier_subscriptions, "retry_count >= 0", name: "supplier_subscriptions_retry_count_check"
  end

  def install_trigger_functions
    execute <<~SQL
      CREATE FUNCTION public.db04_supplier_observation_guard() RETURNS trigger
      LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog AS $$
      BEGIN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_delete_denied'; END IF;
        IF TG_OP = 'INSERT' THEN
          IF NEW.purged_at IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_purged_at_managed'; END IF;
          RETURN NEW;
        END IF;
        IF (NEW.id,NEW.supplier_id,NEW.resource_kind,NEW.external_resource_id,NEW.provider_request_id,NEW.endpoint_key,
            NEW.adapter_version,NEW.payload_schema_version,NEW.payload_sha256,NEW.observed_at,NEW.received_at,NEW.created_at,
            NEW.encryption_context) IS DISTINCT FROM
           (OLD.id,OLD.supplier_id,OLD.resource_kind,OLD.external_resource_id,OLD.provider_request_id,OLD.endpoint_key,
            OLD.adapter_version,OLD.payload_schema_version,OLD.payload_sha256,OLD.observed_at,OLD.received_at,OLD.created_at,
            OLD.encryption_context)
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_immutable'; END IF;
        IF NEW.purge_after > OLD.purge_after THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_deadline_extension_denied'; END IF;
        IF NEW.purged_at IS DISTINCT FROM OLD.purged_at
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_purged_at_managed'; END IF;
        IF OLD.purged_at IS NOT NULL AND (NEW.purged_at IS DISTINCT FROM OLD.purged_at OR NEW.payload_ciphertext IS NOT NULL OR NEW.payload_json IS NOT NULL)
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_restore_denied'; END IF;
        IF OLD.purged_at IS NULL AND NEW.payload_ciphertext IS NULL AND NEW.payload_json IS NULL THEN
          IF pg_catalog.statement_timestamp() < NEW.purge_after
          THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_purge_too_early'; END IF;
          NEW.purged_at := pg_catalog.statement_timestamp();
        ELSIF OLD.payload_json IS DISTINCT FROM NEW.payload_json THEN
          RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='supplier_observation_json_replacement_denied';
        END IF;
        RETURN NEW;
      END $$;

      CREATE FUNCTION public.db04_fact_definition_guard() RETURNS trigger
      LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog AS $$
      BEGIN
        IF TG_OP='UPDATE' AND (NEW.id,NEW.key,NEW.data_type,NEW.unit_dimension,NEW.canonical_unit,NEW.allowed_operators,
            NEW.allowed_operators_schema_version,NEW.allowed_values_schema,NEW.allowed_values_schema_version,
            NEW.hard_eligibility_supported,NEW.version,NEW.created_at) IS DISTINCT FROM
           (OLD.id,OLD.key,OLD.data_type,OLD.unit_dimension,OLD.canonical_unit,OLD.allowed_operators,
            OLD.allowed_operators_schema_version,OLD.allowed_values_schema,OLD.allowed_values_schema_version,
            OLD.hard_eligibility_supported,OLD.version,OLD.created_at)
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_interpretation_immutable'; END IF;
        IF pg_catalog.jsonb_typeof(NEW.allowed_operators)<>'array'
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_operators_invalid'; END IF;
        IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(NEW.allowed_operators) e WHERE pg_catalog.jsonb_typeof(e)<>'string' OR nullif(pg_catalog.btrim(e#>>'{}'),'') IS NULL) OR
           (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_operators)) <>
           (SELECT pg_catalog.count(DISTINCT x) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_operators) x)
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_operators_invalid'; END IF;
        IF NEW.data_type='enum' THEN
          IF pg_catalog.jsonb_typeof(NEW.allowed_values_schema)<>'object' OR NOT (NEW.allowed_values_schema ? 'enum') OR
             (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_object_keys(NEW.allowed_values_schema))<>1 OR
             pg_catalog.jsonb_typeof(NEW.allowed_values_schema->'enum')<>'array' OR pg_catalog.jsonb_array_length(NEW.allowed_values_schema->'enum')=0
          THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_enum_invalid'; END IF;
          IF EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(NEW.allowed_values_schema->'enum') e WHERE pg_catalog.jsonb_typeof(e)<>'string' OR pg_catalog.octet_length(e#>>'{}') > 1024) OR
             (SELECT pg_catalog.count(*) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_values_schema->'enum')) <>
             (SELECT pg_catalog.count(DISTINCT x) FROM pg_catalog.jsonb_array_elements_text(NEW.allowed_values_schema->'enum') x)
          THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='fact_definition_enum_invalid'; END IF;
        END IF;
        RETURN NEW;
      END $$;

      CREATE FUNCTION public.db04_product_fact_validate() RETURNS trigger
      LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog AS $$
      DECLARE d public.fact_definitions%ROWTYPE; valid_enum boolean;
      BEGIN
        SELECT * INTO d FROM public.fact_definitions WHERE id=NEW.fact_definition_id FOR KEY SHARE;
        IF NOT FOUND THEN RAISE EXCEPTION USING ERRCODE='23503', MESSAGE='product_fact_definition_missing'; END IF;
        IF (d.data_type='boolean' AND NEW.boolean_value IS NULL) OR
           (d.data_type='integer' AND NEW.integer_value IS NULL) OR
           (d.data_type IN ('decimal','measurement') AND NEW.decimal_value IS NULL) OR
           (d.data_type IN ('text','enum') AND NEW.text_value IS NULL) OR
           (d.data_type='json' AND NEW.json_value IS NULL)
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_definition_mismatch'; END IF;
        IF d.data_type='measurement' AND NEW.canonical_unit IS DISTINCT FROM d.canonical_unit
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_unit_mismatch'; END IF;
        IF d.data_type<>'measurement' AND NEW.canonical_unit IS NOT NULL
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_unit_mismatch'; END IF;
        IF d.data_type='enum' THEN
          SELECT EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements_text(d.allowed_values_schema->'enum') x WHERE x=NEW.text_value) INTO valid_enum;
          IF NOT valid_enum THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='product_fact_enum_mismatch'; END IF;
        END IF;
        RETURN NEW;
      END $$;

      CREATE FUNCTION public.db04_latest_observation_validate() RETURNS trigger
      LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog AS $$
      DECLARE o record; expected_kind text; expected_external text;
      BEGIN
        IF NEW.latest_observation_id IS NULL THEN RETURN NEW; END IF;
        IF TG_TABLE_NAME='supplier_products' THEN expected_kind:='product'; expected_external:=NEW.external_product_id;
        ELSE expected_kind:='variant'; expected_external:=NEW.external_variant_id; END IF;
        SELECT resource_kind,external_resource_id INTO o FROM public.supplier_observations
          WHERE id=NEW.latest_observation_id AND supplier_id=NEW.supplier_id FOR KEY SHARE;
        IF NOT FOUND OR o.resource_kind<>expected_kind OR o.external_resource_id<>expected_external
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='latest_observation_identity_mismatch'; END IF;
        RETURN NEW;
      END $$;

      CREATE FUNCTION public.db04_encryption_context_immutable() RETURNS trigger
      LANGUAGE plpgsql SECURITY INVOKER SET search_path = pg_catalog AS $$
      BEGIN
        IF NEW.encryption_context IS DISTINCT FROM OLD.encryption_context
        THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='encryption_context_immutable'; END IF;
        RETURN NEW;
      END $$;
    SQL
  end

  def install_triggers
    execute <<~SQL
      CREATE TRIGGER db04_supplier_observation_guard BEFORE INSERT OR UPDATE OR DELETE ON supplier_observations
        FOR EACH ROW EXECUTE FUNCTION public.db04_supplier_observation_guard();
      CREATE TRIGGER db04_fact_definition_guard BEFORE INSERT OR UPDATE ON fact_definitions
        FOR EACH ROW EXECUTE FUNCTION public.db04_fact_definition_guard();
      CREATE TRIGGER db04_product_fact_validate BEFORE INSERT OR UPDATE ON product_facts
        FOR EACH ROW EXECUTE FUNCTION public.db04_product_fact_validate();
      CREATE TRIGGER db04_price_observations_immutable BEFORE UPDATE OR DELETE ON price_observations
        FOR EACH ROW EXECUTE FUNCTION public.nudge_prevent_row_mutation();
      CREATE TRIGGER db04_inventory_observations_immutable BEFORE UPDATE OR DELETE ON inventory_observations
        FOR EACH ROW EXECUTE FUNCTION public.nudge_prevent_row_mutation();
      CREATE TRIGGER db04_supplier_products_latest_observation BEFORE INSERT OR UPDATE OF latest_observation_id,supplier_id,external_product_id ON supplier_products
        FOR EACH ROW EXECUTE FUNCTION public.db04_latest_observation_validate();
      CREATE TRIGGER db04_supplier_variants_latest_observation BEFORE INSERT OR UPDATE OF latest_observation_id,supplier_id,external_variant_id ON supplier_variants
        FOR EACH ROW EXECUTE FUNCTION public.db04_latest_observation_validate();
      CREATE TRIGGER db04_catalog_media_encryption_context BEFORE UPDATE OF encryption_context ON catalog_media
        FOR EACH ROW EXECUTE FUNCTION public.db04_encryption_context_immutable();
      CREATE TRIGGER db04_supplier_subscriptions_encryption_context BEFORE UPDATE OF encryption_context ON supplier_subscriptions
        FOR EACH ROW EXECUTE FUNCTION public.db04_encryption_context_immutable();
    SQL
  end

  def remove_triggers
    execute <<~SQL
      DROP TRIGGER IF EXISTS db04_supplier_variants_latest_observation ON supplier_variants;
      DROP TRIGGER IF EXISTS db04_supplier_products_latest_observation ON supplier_products;
      DROP TRIGGER IF EXISTS db04_supplier_subscriptions_encryption_context ON supplier_subscriptions;
      DROP TRIGGER IF EXISTS db04_catalog_media_encryption_context ON catalog_media;
      DROP TRIGGER IF EXISTS db04_product_fact_validate ON product_facts;
      DROP TRIGGER IF EXISTS db04_inventory_observations_immutable ON inventory_observations;
      DROP TRIGGER IF EXISTS db04_price_observations_immutable ON price_observations;
      DROP TRIGGER IF EXISTS db04_fact_definition_guard ON fact_definitions;
      DROP TRIGGER IF EXISTS db04_supplier_observation_guard ON supplier_observations;
    SQL
  end

  def remove_trigger_functions
    execute <<~SQL
      DROP FUNCTION IF EXISTS public.db04_latest_observation_validate();
      DROP FUNCTION IF EXISTS public.db04_encryption_context_immutable();
      DROP FUNCTION IF EXISTS public.db04_product_fact_validate();
      DROP FUNCTION IF EXISTS public.db04_fact_definition_guard();
      DROP FUNCTION IF EXISTS public.db04_supplier_observation_guard();
    SQL
  end

  def add_latest_observation_constraints
    add_foreign_key :supplier_products, :supplier_observations, column: %i[latest_observation_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, validate: false, name: "fk_supplier_products_latest_observation"
    add_foreign_key :supplier_variants, :supplier_observations, column: %i[latest_observation_id supplier_id], primary_key: %i[id supplier_id], on_delete: :restrict, on_update: :restrict, deferrable: false, validate: false, name: "fk_supplier_variants_latest_observation"
    execute <<~SQL
      DO $$ BEGIN
        IF EXISTS (
          SELECT 1 FROM supplier_products p JOIN supplier_observations o ON o.id=p.latest_observation_id
          WHERE p.latest_observation_id IS NOT NULL AND (o.supplier_id<>p.supplier_id OR o.resource_kind<>'product' OR o.external_resource_id<>p.external_product_id)
        ) OR EXISTS (
          SELECT 1 FROM supplier_variants v JOIN supplier_observations o ON o.id=v.latest_observation_id
          WHERE v.latest_observation_id IS NOT NULL AND (o.supplier_id<>v.supplier_id OR o.resource_kind<>'variant' OR o.external_resource_id<>v.external_variant_id)
        ) THEN RAISE EXCEPTION USING ERRCODE='23514', MESSAGE='latest_observation_identity_audit_failed'; END IF;
      END $$;
    SQL
    validate_foreign_key :supplier_products, name: "fk_supplier_products_latest_observation"
    validate_foreign_key :supplier_variants, name: "fk_supplier_variants_latest_observation"
  end

  def remove_latest_observation_constraints
    remove_foreign_key :supplier_variants, name: "fk_supplier_variants_latest_observation"
    remove_foreign_key :supplier_products, name: "fk_supplier_products_latest_observation"
  end
end
