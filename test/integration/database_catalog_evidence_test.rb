require "test_helper"
require "pg"

class DatabaseCatalogEvidenceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TABLES = %w[
    supplier_observations catalog_media fact_definitions product_facts
    price_observations inventory_observations sync_runs sync_checkpoints
    supplier_subscriptions
  ].freeze

  setup { reset_database_rows }
  teardown { reset_database_rows }

  test "installs the complete DB-04 evidence and synchronization boundary" do
    TABLES.each { |table| assert connection.data_source_exists?(table), table }
    assert_equal %w[id supplier_id], index_columns("supplier_variants", true).find { |columns| columns == %w[id supplier_id] }
    assert_equal %w[id supplier_id], index_columns("supplier_warehouses", true).find { |columns| columns == %w[id supplier_id] }

    %w[fk_supplier_products_latest_observation fk_supplier_variants_latest_observation].each do |name|
      row = connection.select_one(<<~SQL)
        SELECT convalidated::text, confdeltype
        FROM pg_constraint
        WHERE conname = #{connection.quote(name)}
      SQL
      assert_equal "true", row.fetch("convalidated")
      assert_equal "r", row.fetch("confdeltype")
    end
  end

  test "creates the exact DB-04 column dictionary" do
    expected = {
      "supplier_observations" => %w[id supplier_id resource_kind external_resource_id provider_request_id endpoint_key adapter_version payload_schema_version payload_ciphertext payload_json payload_sha256 encryption_context observed_at received_at normalization_status normalization_error_code purge_after purged_at created_at],
      "catalog_media" => %w[id product_id product_variant_id supplier_observation_id kind original_url_ciphertext encryption_context sanitized_url object_key mime_type width height checksum position status observed_at verified_at created_at updated_at],
      "fact_definitions" => %w[id key label description data_type unit_dimension canonical_unit allowed_operators allowed_operators_schema_version allowed_values_schema allowed_values_schema_version hard_eligibility_supported version status created_at updated_at],
      "product_facts" => %w[id product_id product_variant_id fact_definition_id boolean_value integer_value decimal_value text_value json_value value_schema_version canonical_unit source_kind supplier_observation_id confidence inference_version observed_at valid_from valid_until status supersedes_product_fact_id created_at updated_at],
      "price_observations" => %w[id supplier_id supplier_variant_id supplier_observation_id amount_minor currency price_kind quantity_tier observed_at valid_until created_at],
      "inventory_observations" => %w[id supplier_id supplier_variant_id supplier_warehouse_id supplier_observation_id total_quantity cj_quantity factory_quantity verification_state observed_at valid_until created_at],
      "sync_runs" => %w[id public_id supplier_id mode resource_kind scope_key scope_json scope_schema_version adapter_version status points_consumed seen_count created_count updated_count error_count started_at completed_at error_code created_at updated_at],
      "sync_checkpoints" => %w[id sync_run_id checkpoint_key cursor page_number state_json state_schema_version created_at updated_at],
      "supplier_subscriptions" => %w[id supplier_id supplier_product_id topic external_ref_ciphertext external_ref_digest digest_key_version encryption_context status requested_at confirmed_at last_verified_at closed_at close_reason retry_count next_retry_at created_at updated_at]
    }
    expected.each do |table, columns|
      assert_equal columns.sort, connection.columns(table).map(&:name).sort, table
    end
  end

  test "uses the canonical observation lifecycle and rejects destructive evidence changes" do
    supplier_id = insert_supplier
    observation_id = insert_observation(supplier_id: supplier_id)

    assert_database_error("supplier_observation_immutable") do
      connection.execute("UPDATE supplier_observations SET endpoint_key = 'changed' WHERE id = #{observation_id}")
    end
    assert_database_error("supplier_observation_delete_denied") do
      connection.execute("DELETE FROM supplier_observations WHERE id = #{observation_id}")
    end
    assert_database_error do
      connection.execute("UPDATE supplier_observations SET payload_json = '{\"changed\":true}'::jsonb WHERE id = #{observation_id}")
    end
    assert_database_error do
      insert_observation(supplier_id: supplier_id, payload_json: "[]")
    end
    assert_database_error do
      connection.execute("UPDATE supplier_observations SET payload_json = NULL, purged_at = CURRENT_TIMESTAMP WHERE id = #{observation_id}")
    end
    connection.execute("UPDATE supplier_observations SET purge_after = CURRENT_TIMESTAMP WHERE id = #{observation_id}")
    connection.execute("UPDATE supplier_observations SET payload_json = NULL, purged_at = CURRENT_TIMESTAMP WHERE id = #{observation_id}")
    assert_nil connection.select_value("SELECT payload_json FROM supplier_observations WHERE id = #{observation_id}")
    assert_database_error("supplier_observation_restore_denied") do
      connection.execute("UPDATE supplier_observations SET payload_json = '{\"restored\":true}'::jsonb WHERE id = #{observation_id}")
    end
  end

  test "validates typed facts against an immutable locked definition" do
    supplier_id = insert_supplier
    product_id = insert_product
    observation_id = insert_observation(supplier_id: supplier_id)
    definition_id = insert_definition

    assert_database_error("fact_definition_interpretation_immutable") do
      connection.execute("UPDATE fact_definitions SET data_type = 'text' WHERE id = #{definition_id}")
    end
    insert_fact(product_id:, observation_id:, definition_id:, decimal: "12.500000", unit: "g")
    assert_database_error("product_fact_definition_mismatch") do
      insert_fact(product_id:, observation_id:, definition_id:, text: "12.5", unit: "g")
    end
    assert_database_error do
      connection.execute("UPDATE product_facts SET decimal_value = 'NaN'::numeric")
    end
  end

  test "enforces supplier scope for observations and latest pointers" do
    supplier_id = insert_supplier
    other_supplier_id = insert_supplier(key: "other")
    product_id = insert_product
    supplier_product_id = insert_supplier_product(supplier_id:, product_id:)
    observation_id = insert_observation(supplier_id:, kind: "product", external_id: "external-product")
    connection.execute("UPDATE supplier_products SET latest_observation_id = #{observation_id} WHERE id = #{supplier_product_id}")

    wrong = insert_observation(supplier_id: other_supplier_id, kind: "product", external_id: "external-product")
    assert_database_error do
      connection.execute("UPDATE supplier_products SET latest_observation_id = #{wrong} WHERE id = #{supplier_product_id}")
    end
    mismatched = insert_observation(supplier_id:, kind: "product", external_id: "wrong")
    assert_database_error("latest_observation_identity_mismatch") do
      connection.execute("UPDATE supplier_products SET latest_observation_id = #{mismatched} WHERE id = #{supplier_product_id}")
    end
  end

  test "enforces media observation sync and subscription bounds" do
    supplier_id = insert_supplier
    other_supplier_id = insert_supplier(key: "other")
    product_id = insert_product
    supplier_product_id = insert_supplier_product(supplier_id:, product_id:)
    observation_id = insert_observation(supplier_id:)

    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO catalog_media (product_id,product_variant_id,kind,position,status,created_at,updated_at)
        VALUES (#{product_id},1,'image',0,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      SQL
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO catalog_media (product_id,kind,width,position,status,created_at,updated_at)
        VALUES (#{product_id},'image',-1,0,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      SQL
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO sync_runs (supplier_id,mode,resource_kind,scope_key,scope_json,scope_schema_version,adapter_version,status,completed_at,created_at,updated_at)
        VALUES (#{supplier_id},'fixture','product','all','{}',1,'v1','succeeded',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      SQL
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO supplier_subscriptions
          (supplier_id,supplier_product_id,topic,external_ref_ciphertext,external_ref_digest,digest_key_version,status,requested_at,created_at,updated_at)
        VALUES (#{supplier_id},#{supplier_product_id},'product','cipher',decode(repeat('ab',31),'hex'),1,'requested',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      SQL
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO supplier_subscriptions
          (supplier_id,supplier_product_id,topic,status,requested_at,created_at,updated_at)
        VALUES (#{other_supplier_id},#{supplier_product_id},'product','requested',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      SQL
    end

    context = connection.select_value(<<~SQL)
      INSERT INTO catalog_media (product_id,supplier_observation_id,kind,position,status,created_at,updated_at)
      VALUES (#{product_id},#{observation_id},'image',0,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      RETURNING encryption_context
    SQL
    assert_database_error("encryption_context_immutable") do
      connection.execute("UPDATE catalog_media SET encryption_context=gen_random_uuid() WHERE encryption_context=#{connection.quote(context)}")
    end
  end

  test "rejects malformed definition schemas with stable errors" do
    assert_database_error("fact_definition_operators_invalid") do
      connection.execute(<<~SQL)
        INSERT INTO fact_definitions
          (key,label,data_type,allowed_operators,allowed_operators_schema_version,hard_eligibility_supported,version,status,created_at,updated_at)
        VALUES ('bad.ops','Bad','text','{}',1,false,1,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      SQL
    end
    assert_database_error("fact_definition_enum_invalid") do
      connection.execute(<<~SQL)
        INSERT INTO fact_definitions
          (key,label,data_type,allowed_operators,allowed_operators_schema_version,allowed_values_schema,allowed_values_schema_version,hard_eligibility_supported,version,status,created_at,updated_at)
        VALUES ('bad.enum','Bad','enum','[]',1,'{"enum":["x","x"]}',1,false,1,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      SQL
    end
  end

  test "enforces supplier scoped price and inventory evidence" do
    supplier_id = insert_supplier
    other_supplier_id = insert_supplier(key: "other")
    product_id = insert_product
    product_variant_id = insert_product_variant(product_id:)
    supplier_product_id = insert_supplier_product(supplier_id:, product_id:)
    supplier_variant_id = insert_supplier_variant(supplier_id:, supplier_product_id:, product_variant_id:)
    warehouse_id = insert_warehouse(supplier_id:)
    observation_id = insert_observation(supplier_id:, kind: "stock", external_id: "stock")
    other_observation_id = insert_observation(supplier_id: other_supplier_id, kind: "stock", external_id: "stock")

    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO price_observations (supplier_id,supplier_variant_id,supplier_observation_id,amount_minor,currency,price_kind,observed_at)
        VALUES (#{supplier_id},#{supplier_variant_id},#{observation_id},-1,'USD','retail',CURRENT_TIMESTAMP)
      SQL
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO price_observations (supplier_id,supplier_variant_id,supplier_observation_id,amount_minor,currency,price_kind,observed_at)
        VALUES (#{supplier_id},#{supplier_variant_id},#{other_observation_id},1,'USD','retail',CURRENT_TIMESTAMP)
      SQL
    end
    price_id = connection.select_value(<<~SQL).to_i
      INSERT INTO price_observations (supplier_id,supplier_variant_id,supplier_observation_id,amount_minor,currency,price_kind,observed_at)
      VALUES (#{supplier_id},#{supplier_variant_id},#{observation_id},0,'USD','retail',CURRENT_TIMESTAMP) RETURNING id
    SQL
    assert_database_error("price_observations rows are immutable") do
      connection.execute("UPDATE price_observations SET amount_minor=1 WHERE id=#{price_id}")
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO inventory_observations (supplier_id,supplier_variant_id,supplier_warehouse_id,supplier_observation_id,observed_at)
        VALUES (#{supplier_id},#{supplier_variant_id},#{warehouse_id},#{observation_id},CURRENT_TIMESTAMP)
      SQL
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO inventory_observations (supplier_id,supplier_variant_id,supplier_warehouse_id,supplier_observation_id,total_quantity,observed_at)
        VALUES (#{supplier_id},#{supplier_variant_id},#{warehouse_id},#{observation_id},-1,CURRENT_TIMESTAMP)
      SQL
    end
    inventory_id = connection.select_value(<<~SQL).to_i
      INSERT INTO inventory_observations (supplier_id,supplier_variant_id,supplier_warehouse_id,supplier_observation_id,total_quantity,observed_at)
      VALUES (#{supplier_id},#{supplier_variant_id},#{warehouse_id},#{observation_id},0,CURRENT_TIMESTAMP) RETURNING id
    SQL
    assert_database_error("inventory_observations rows are immutable") do
      connection.execute("DELETE FROM inventory_observations WHERE id=#{inventory_id}")
    end
    assert_database_error do
      connection.execute(<<~SQL)
        INSERT INTO inventory_observations (supplier_id,supplier_variant_id,supplier_warehouse_id,supplier_observation_id,total_quantity,observed_at)
        VALUES (#{supplier_id},#{supplier_variant_id},#{warehouse_id},#{observation_id},1,CURRENT_TIMESTAMP)
      SQL
    end
  end

  test "serializes competing logical subscription inserts" do
    supplier_id = insert_supplier
    product_id = insert_product
    supplier_product_id = insert_supplier_product(supplier_id:, product_id:)
    sql = <<~SQL
      INSERT INTO supplier_subscriptions
        (supplier_id,supplier_product_id,topic,status,requested_at,created_at,updated_at)
      VALUES (#{supplier_id},#{supplier_product_id},'product','requested',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
    SQL
    results = concurrent_statements([ sql, sql ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)
  end

  private

  def connection = ActiveRecord::Base.connection

  def reset_database_rows
    connection.execute("TRUNCATE #{(TABLES + %w[supplier_warehouses supplier_variants supplier_products product_variants product_categories products categories suppliers]).join(', ')} RESTART IDENTITY CASCADE")
  end

  def index_columns(table, unique)
    connection.indexes(table).select { |index| index.unique == unique }.map(&:columns)
  end

  def assert_database_error(message = nil)
    error = assert_raises(ActiveRecord::StatementInvalid) { yield }
    assert_includes error.message, message if message
  end

  def insert_supplier(key: "supplier")
    connection.select_value(<<~SQL).to_i
      INSERT INTO suppliers (key,display_name,adapter_version,api_version,status,created_at,updated_at)
      VALUES (#{connection.quote(key)},'Supplier','v1','v1','active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING id
    SQL
  end

  def insert_product
    connection.select_value(<<~SQL).to_i
      INSERT INTO products (status,title,description,lock_version,created_at,updated_at)
      VALUES ('draft','Product','',0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING id
    SQL
  end

  def insert_supplier_product(supplier_id:, product_id:)
    connection.select_value(<<~SQL).to_i
      INSERT INTO supplier_products
        (supplier_id,product_id,external_product_id,status,first_seen_at,last_seen_at,adapter_version,created_at,updated_at)
      VALUES (#{supplier_id},#{product_id},'external-product','active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,'v1',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      RETURNING id
    SQL
  end

  def insert_product_variant(product_id:)
    connection.select_value(<<~SQL).to_i
      INSERT INTO product_variants
        (product_id,title,option_summary,option_schema_version,status,lock_version,created_at,updated_at)
      VALUES (#{product_id},'Variant','{}',1,'active',0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING id
    SQL
  end

  def insert_supplier_variant(supplier_id:, supplier_product_id:, product_variant_id:)
    connection.select_value(<<~SQL).to_i
      INSERT INTO supplier_variants
        (supplier_id,product_variant_id,supplier_product_id,external_variant_id,status,first_seen_at,last_seen_at,created_at,updated_at)
      VALUES (#{supplier_id},#{product_variant_id},#{supplier_product_id},'external-variant','active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      RETURNING id
    SQL
  end

  def insert_warehouse(supplier_id:)
    connection.select_value(<<~SQL).to_i
      INSERT INTO supplier_warehouses
        (supplier_id,external_warehouse_id,status,first_seen_at,last_seen_at,created_at,updated_at)
      VALUES (#{supplier_id},'warehouse','active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      RETURNING id
    SQL
  end

  def insert_observation(supplier_id:, kind: "product", external_id: "external-product", payload_json: '{"ok":true}')
    connection.select_value(<<~SQL).to_i
      INSERT INTO supplier_observations
        (supplier_id,resource_kind,external_resource_id,endpoint_key,adapter_version,payload_schema_version,
         payload_json,payload_sha256,observed_at,received_at,purge_after,created_at)
      VALUES (#{supplier_id},#{connection.quote(kind)},#{connection.quote(external_id)},'catalog','v1',1,
        #{connection.quote(payload_json)}::jsonb,decode(repeat('ab',32),'hex'),CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,
        CURRENT_TIMESTAMP + interval '30 days',CURRENT_TIMESTAMP) RETURNING id
    SQL
  end

  def insert_definition
    connection.select_value(<<~SQL).to_i
      INSERT INTO fact_definitions
        (key,label,data_type,unit_dimension,canonical_unit,allowed_operators,allowed_operators_schema_version,
         hard_eligibility_supported,version,status,created_at,updated_at)
      VALUES ('weight.v1','Weight','measurement','mass','g','["eq","lte"]',1,false,1,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
      RETURNING id
    SQL
  end

  def insert_fact(product_id:, observation_id:, definition_id:, decimal: nil, text: nil, unit: nil)
    connection.execute(<<~SQL)
      INSERT INTO product_facts
        (product_id,fact_definition_id,decimal_value,text_value,canonical_unit,source_kind,supplier_observation_id,
         observed_at,status,created_at,updated_at)
      VALUES (#{product_id},#{definition_id},#{decimal || 'NULL'},#{text ? connection.quote(text) : 'NULL'},
        #{unit ? connection.quote(unit) : 'NULL'},'supplier',#{observation_id},CURRENT_TIMESTAMP,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
    SQL
  end

  def concurrent_statements(statements)
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
