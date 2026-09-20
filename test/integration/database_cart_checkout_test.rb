require "test_helper"
require "digest"
require "pg"
require "securerandom"

# DB-07: Slice 08 -- carts, cart items/mutations, checkout validations/items,
# freight quotes, and checkout intents (.planning/PHYSICAL_SCHEMA.md lines 130-131,
# section 8 "Cart, checkout, snapshots, and payments"). Tests written against the
# approved schema before the DB-07 migration exists; they are expected to fail with
# missing-relation errors until the migration lands.
class DatabaseCartCheckoutTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TABLES = %w[
    freight_quotes
    checkout_validation_items
    checkout_validations
    checkout_intents
    cart_mutations
    cart_items
    carts
  ].freeze

  setup { truncate_cart_tables }
  teardown { truncate_cart_tables }

  test "installs the complete Slice 08 cart and checkout intent boundary" do
    TABLES.each { |table| assert connection.data_source_exists?(table), table }
  end

  test "creates the exact DB-07 column dictionary" do
    expected = {
      "carts" => %w[id public_id shopping_session_id user_id status currency lock_version last_activity_at expires_at created_at updated_at],
      "cart_items" => %w[id cart_id product_variant_id quantity last_displayed_unit_amount_minor currency price_observation_id lock_version added_at created_at updated_at],
      "cart_mutations" => %w[id cart_id client_mutation_id operation product_variant_id requested_quantity quantity_delta request_hash status result_snapshot result_schema_version error_code started_at completed_at created_at updated_at],
      "checkout_validations" => %w[id public_id cart_id status failure_reason destination_country destination_region destination_ciphertext started_at completed_at expires_at total_policy_version margin_policy_version created_at updated_at],
      "checkout_validation_items" => %w[id checkout_validation_id product_variant_id requested_quantity inventory_result supplier_amount_minor currency freight_result destination_result margin_result overall_result price_observation_id inventory_observation_id evidence_observed_at created_at updated_at],
      "freight_quotes" => %w[id checkout_validation_id supplier_id provider_ref_ciphertext provider_ref_digest digest_key_version warehouse_external_id logistics_id logistics_name amount_minor currency delivery_min_days delivery_max_days supplier_observation_id quoted_at expires_at created_at updated_at],
      "checkout_intents" => %w[id public_id execution_mode cart_id provider intent_key request_hash status blocked_reason started_at completed_at expires_at lock_version created_at updated_at]
    }
    expected.each do |table, columns|
      assert_equal columns.sort, connection.columns(table).map(&:name).sort, table
    end
  end

  # --- Carts -----------------------------------------------------------

  test "allows exactly one active cart per shopping session under genuine concurrent creation" do
    session_id = insert_session

    sql = cart_insert_sql(session_id: session_id, status: "active")
    results = concurrent_inserts([ sql, sql ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)

    # a non-active cart for the same session does not collide with the partial index
    assert insert_cart(session_id: session_id, status: "abandoned")
  end

  test "requires positive cart item quantities" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    variant_id = insert_variant(product_id: insert_product)

    assert_constraint(:check) { insert_cart_item(cart_id: cart_id, variant_id: variant_id, quantity: 0) }
    assert_constraint(:check) { insert_cart_item(cart_id: cart_id, variant_id: variant_id, quantity: -1) }
    assert insert_cart_item(cart_id: cart_id, variant_id: variant_id, quantity: 1)
  end

  test "enforces cart item uniqueness per cart and variant" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    variant_id = insert_variant(product_id: insert_product)

    insert_cart_item(cart_id: cart_id, variant_id: variant_id, quantity: 1)
    assert_constraint(:unique) { insert_cart_item(cart_id: cart_id, variant_id: variant_id, quantity: 2) }
  end

  # --- Cart mutations ----------------------------------------------------

  test "rejects cart mutation reuse under a mismatched request hash" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    variant_id = insert_variant(product_id: insert_product)
    client_mutation_id = SecureRandom.uuid

    insert_cart_mutation(cart_id: cart_id, variant_id: variant_id, client_mutation_id: client_mutation_id, hash: digest("hash-one"))
    error = assert_constraint(:unique) do
      insert_cart_mutation(cart_id: cart_id, variant_id: variant_id, client_mutation_id: client_mutation_id, hash: digest("hash-two"))
    end
    assert_includes error.message, "cart_mutations"
  end

  test "rejects cart mutations that combine a requested quantity with a delta" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    variant_id = insert_variant(product_id: insert_product)

    assert_constraint(:check) do
      insert_cart_mutation(cart_id: cart_id, variant_id: variant_id, requested_quantity: 5, quantity_delta: 1)
    end
    assert insert_cart_mutation(cart_id: cart_id, variant_id: variant_id, requested_quantity: 5, quantity_delta: nil)
  end

  test "requires a 32-byte cart mutation request hash" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    variant_id = insert_variant(product_id: insert_product)

    assert_constraint(:check) { insert_cart_mutation(cart_id: cart_id, variant_id: variant_id, hash: "short") }
  end

  # --- Checkout intents ----------------------------------------------------

  test "enforces a single order-intent identity per execution mode, cart, provider, and intent key" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)

    insert_checkout_intent(cart_id: cart_id, intent_key: "intent-1", hash: digest("payload-one"))
    assert_constraint(:unique) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "intent-1", hash: digest("payload-two"))
    end
  end

  test "serializes genuinely concurrent identical checkout intent creation to a single row" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    hash = digest("identical-payload")

    sql = checkout_intent_insert_sql(cart_id: cart_id, intent_key: "concurrent-intent", hash: hash)
    results = concurrent_inserts([ sql, sql ])
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count(PG::UniqueViolation)
    assert_equal 1, connection.select_value(<<~SQL).to_i
      SELECT count(*) FROM checkout_intents WHERE cart_id = #{cart_id} AND intent_key = 'concurrent-intent'
    SQL
  end

  test "denies application-role mutation of checkout intent execution mode" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    intent_id = insert_checkout_intent(cart_id: cart_id, intent_key: "immutable-mode", hash: digest("payload"))

    error = assert_raises(ActiveRecord::StatementInvalid) do
      connection.execute("UPDATE checkout_intents SET execution_mode = 'sandbox' WHERE id = #{intent_id}")
    end
    assert_includes error.message, "checkout_intents.execution_mode is immutable"
  end

  test "enforces checkout intent status and timing invariants" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)

    assert_constraint(:check) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "bad-status", hash: digest("a"), status: "unknown")
    end
    assert_constraint(:check) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "bad-expiry", hash: digest("b"),
        started_at: reference_time, expires_at: reference_time)
    end
    assert_constraint(:check) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "blocked-without-reason", hash: digest("c"),
        status: "blocked", blocked_reason: nil)
    end
    assert_constraint(:check) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "open-with-reason", hash: digest("d"),
        status: "open", blocked_reason: "should not be present")
    end
    assert_constraint(:check) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "converted-without-completion", hash: digest("e"),
        status: "converted", completed_at: nil)
    end
    assert_constraint(:check) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "open-with-completion", hash: digest("f"),
        status: "open", completed_at: reference_time)
    end
    assert_constraint(:check) do
      insert_checkout_intent(cart_id: cart_id, intent_key: "completed-before-start", hash: digest("g"),
        status: "converted", started_at: reference_time, completed_at: reference_time - 1)
    end

    assert insert_checkout_intent(cart_id: cart_id, intent_key: "valid-blocked", hash: digest("h"),
      status: "blocked", blocked_reason: "ambiguous provider outcome")
    assert insert_checkout_intent(cart_id: cart_id, intent_key: "valid-converted", hash: digest("i"),
      status: "converted", started_at: reference_time, completed_at: reference_time + 1)
  end

  test "indexes unexpired open and blocked checkout intents by expiry" do
    index = connection.indexes("checkout_intents").find { |candidate| candidate.columns.include?("expires_at") && candidate.where.present? }
    assert index, "expected a partial index on checkout_intents.expires_at scoped to open/blocked rows"
    assert_match(/open/, index.where)
    assert_match(/blocked/, index.where)
  end

  # --- Checkout validations and items ----------------------------------------------------

  test "enforces checkout validation item results and uniqueness" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    validation_id = insert_checkout_validation(cart_id: cart_id)
    variant_id = insert_variant(product_id: insert_product)

    assert_constraint(:check) { insert_checkout_validation_item(validation_id: validation_id, variant_id: variant_id, quantity: 0) }
    assert_constraint(:check) do
      insert_checkout_validation_item(validation_id: validation_id, variant_id: variant_id, overall_result: "maybe")
    end
    assert_constraint(:check) do
      insert_checkout_validation_item(validation_id: validation_id, variant_id: variant_id, supplier_amount_minor: 100, currency: nil)
    end

    insert_checkout_validation_item(validation_id: validation_id, variant_id: variant_id)
    assert_constraint(:unique) { insert_checkout_validation_item(validation_id: validation_id, variant_id: variant_id) }
  end

  test "enforces checkout validation status vocabulary and expiry ordering" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)

    assert_constraint(:check) { insert_checkout_validation(cart_id: cart_id, status: "unknown") }
    assert_constraint(:check) do
      insert_checkout_validation(cart_id: cart_id, started_at: reference_time, expires_at: reference_time - 1)
    end
    assert insert_checkout_validation(cart_id: cart_id)
  end

  # --- Freight quotes ----------------------------------------------------

  test "enforces freight quote association and value rules" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    validation_id = insert_checkout_validation(cart_id: cart_id)
    supplier_id = insert_supplier

    assert_constraint(:check) { insert_freight_quote(validation_id: validation_id, supplier_id: supplier_id, amount_minor: -1) }
    assert_constraint(:check) { insert_freight_quote(validation_id: validation_id, supplier_id: supplier_id, delivery_min_days: 5, delivery_max_days: 1) }
    assert_constraint(:check) do
      insert_freight_quote(validation_id: validation_id, supplier_id: supplier_id, quoted_at: reference_time, expires_at: reference_time - 1)
    end
    assert_constraint(:check) do
      insert_freight_quote(validation_id: validation_id, supplier_id: supplier_id, provider_ref_ciphertext: "cipher", provider_ref_digest: nil)
    end

    assert insert_freight_quote(validation_id: validation_id, supplier_id: supplier_id, delivery_min_days: 1, delivery_max_days: 3)
  end

  # --- Delete rules ----------------------------------------------------

  test "declares SET NULL delete rules for observation-linked evidence columns" do
    assert_set_null_delete_rule("cart_items", "price_observation_id")
    assert_set_null_delete_rule("checkout_validation_items", "price_observation_id")
    assert_set_null_delete_rule("checkout_validation_items", "inventory_observation_id")
    assert_set_null_delete_rule("freight_quotes", "supplier_observation_id")
  end

  test "enforces RESTRICT delete rules across cart and checkout foreign keys" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)

    assert_constraint(:foreign_key) { connection.execute("DELETE FROM shopping_sessions WHERE id = #{session_id}") }

    variant_id = insert_variant(product_id: insert_product)
    insert_cart_item(cart_id: cart_id, variant_id: variant_id)
    assert_constraint(:foreign_key) { connection.execute("DELETE FROM product_variants WHERE id = #{variant_id}") }

    validation_id = insert_checkout_validation(cart_id: cart_id)
    assert_constraint(:foreign_key) { connection.execute("DELETE FROM carts WHERE id = #{cart_id}") }

    supplier_id = insert_supplier
    insert_freight_quote(validation_id: validation_id, supplier_id: supplier_id)
    assert_constraint(:foreign_key) { connection.execute("DELETE FROM suppliers WHERE id = #{supplier_id}") }
  end

  test "cascades cart and checkout validation deletes to their ephemeral children" do
    session_id = insert_session
    cart_id = insert_cart(session_id: session_id)
    variant_id = insert_variant(product_id: insert_product)
    item_id = insert_cart_item(cart_id: cart_id, variant_id: variant_id)
    mutation_id = insert_cart_mutation(cart_id: cart_id, variant_id: variant_id)

    connection.execute("DELETE FROM carts WHERE id = #{cart_id}")
    assert_nil connection.select_value("SELECT id FROM cart_items WHERE id = #{item_id}")
    assert_nil connection.select_value("SELECT id FROM cart_mutations WHERE id = #{mutation_id}")

    cart_id = insert_cart(session_id: session_id)
    validation_id = insert_checkout_validation(cart_id: cart_id)
    supplier_id = insert_supplier
    validation_item_id = insert_checkout_validation_item(validation_id: validation_id, variant_id: variant_id)
    quote_id = insert_freight_quote(validation_id: validation_id, supplier_id: supplier_id)

    connection.execute("DELETE FROM checkout_validations WHERE id = #{validation_id}")
    assert_nil connection.select_value("SELECT id FROM checkout_validation_items WHERE id = #{validation_item_id}")
    assert_nil connection.select_value("SELECT id FROM freight_quotes WHERE id = #{quote_id}")
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def truncate_cart_tables
    connection.execute("TRUNCATE #{(TABLES + %w[product_variants products suppliers shopping_sessions]).join(', ')} RESTART IDENTITY CASCADE")
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
    value.nil? ? "NULL" : "decode('#{value.b.unpack1('H*')}', 'hex')"
  end

  def insert_returning(sql)
    connection.execute("#{sql} RETURNING id").first.fetch("id").to_i
  end

  def assert_constraint(kind = nil, &block)
    error = assert_raises(ActiveRecord::StatementInvalid, &block)
    cause = error.cause || error
    case kind
    when :unique
      assert(error.is_a?(ActiveRecord::RecordNotUnique) || cause.is_a?(PG::UniqueViolation),
        "expected a unique violation, got #{error.class}: #{error.message}")
    when :check
      assert_kind_of PG::CheckViolation, cause, "expected a check violation, got #{error.class}: #{error.message}"
    when :not_null
      assert_kind_of PG::NotNullViolation, cause, "expected a not-null violation, got #{error.class}: #{error.message}"
    when :foreign_key
      assert(
        error.is_a?(ActiveRecord::InvalidForeignKey) || cause.is_a?(PG::ForeignKeyViolation) || cause.is_a?(PG::RestrictViolation),
        "expected a foreign-key violation, got #{error.class}: #{error.message}"
      )
    end
    error
  end

  def assert_set_null_delete_rule(table, column)
    row = connection.select_one(<<~SQL)
      SELECT confdeltype
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
      WHERE c.conrelid = #{connection.quote(table)}::regclass
        AND c.contype = 'f'
        AND a.attname = #{connection.quote(column)}
        AND array_length(c.conkey, 1) = 1
    SQL
    assert row, "expected a single-column foreign key on #{table}.#{column}"
    assert_equal "n", row.fetch("confdeltype"), "#{table}.#{column} should ON DELETE SET NULL"
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

  # --- fixtures ----------------------------------------------------

  def insert_session(status: "active")
    insert_returning(<<~SQL.squish)
      INSERT INTO shopping_sessions (status, started_at, last_activity_at, expires_at, abuse_level, created_at, updated_at)
      VALUES (#{q(status)}, #{q(reference_time)}, #{q(reference_time)}, #{q(reference_time + 3600)}, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_product
    insert_returning(<<~SQL.squish)
      INSERT INTO products (status, title, description, lock_version, created_at, updated_at)
      VALUES ('draft', 'Product', '', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_variant(product_id:)
    insert_returning(<<~SQL.squish)
      INSERT INTO product_variants (product_id, title, option_summary, option_schema_version, status, lock_version, created_at, updated_at)
      VALUES (#{product_id}, 'Variant', '{}', 1, 'active', 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_supplier(key: "supplier-#{SecureRandom.hex(4)}")
    insert_returning(<<~SQL.squish)
      INSERT INTO suppliers (key, display_name, adapter_version, api_version, status, created_at, updated_at)
      VALUES (#{q(key)}, 'Supplier', 'v1', 'v1', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def cart_insert_sql(session_id:, status: "active", currency: "USD")
    <<~SQL.squish
      INSERT INTO carts (shopping_session_id, status, currency, last_activity_at, expires_at, created_at, updated_at)
      VALUES (#{session_id}, #{q(status)}, #{q(currency)}, #{q(reference_time)}, #{q(reference_time + 3600)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_cart(session_id:, status: "active", currency: "USD")
    insert_returning(cart_insert_sql(session_id: session_id, status: status, currency: currency))
  end

  def insert_cart_item(cart_id:, variant_id:, quantity: 1)
    insert_returning(<<~SQL.squish)
      INSERT INTO cart_items (cart_id, product_variant_id, quantity, added_at, created_at, updated_at)
      VALUES (#{cart_id}, #{variant_id}, #{quantity}, #{q(reference_time)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_cart_mutation(cart_id:, variant_id:, client_mutation_id: SecureRandom.uuid, operation: "set_quantity",
                            requested_quantity: 1, quantity_delta: nil, hash: digest("mutation"), status: "pending")
    insert_returning(<<~SQL.squish)
      INSERT INTO cart_mutations
        (cart_id, client_mutation_id, operation, product_variant_id, requested_quantity, quantity_delta,
         request_hash, status, started_at, created_at, updated_at)
      VALUES
        (#{cart_id}, #{q(client_mutation_id)}, #{q(operation)}, #{variant_id},
         #{requested_quantity || "NULL"}, #{quantity_delta || "NULL"},
         #{bytea(hash)}, #{q(status)}, #{q(reference_time)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_checkout_validation(cart_id:, status: "pending", country: "US", started_at: reference_time, expires_at: reference_time + 3600)
    insert_returning(<<~SQL.squish)
      INSERT INTO checkout_validations
        (cart_id, status, destination_country, started_at, expires_at, total_policy_version, margin_policy_version, created_at, updated_at)
      VALUES
        (#{cart_id}, #{q(status)}, #{q(country)}, #{q(started_at)}, #{q(expires_at)}, 'v1', 'v1', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_checkout_validation_item(validation_id:, variant_id:, quantity: 1, inventory_result: "pass",
                                       freight_result: "pass", destination_result: "pass", margin_result: "pass",
                                       overall_result: "pass", supplier_amount_minor: nil, currency: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO checkout_validation_items
        (checkout_validation_id, product_variant_id, requested_quantity, inventory_result, supplier_amount_minor,
         currency, freight_result, destination_result, margin_result, overall_result, evidence_observed_at,
         created_at, updated_at)
      VALUES
        (#{validation_id}, #{variant_id}, #{quantity}, #{q(inventory_result)},
         #{supplier_amount_minor || "NULL"}, #{currency ? q(currency) : "NULL"}, #{q(freight_result)},
         #{q(destination_result)}, #{q(margin_result)}, #{q(overall_result)}, #{q(reference_time)},
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_freight_quote(validation_id:, supplier_id:, warehouse_external_id: "warehouse", logistics_id: "logistics",
                            logistics_name: "Logistics", amount_minor: 100, currency: "USD",
                            delivery_min_days: nil, delivery_max_days: nil, quoted_at: reference_time,
                            expires_at: reference_time + 3600, provider_ref_ciphertext: nil, provider_ref_digest: nil)
    insert_returning(<<~SQL.squish)
      INSERT INTO freight_quotes
        (checkout_validation_id, supplier_id, provider_ref_ciphertext, provider_ref_digest, digest_key_version,
         warehouse_external_id, logistics_id, logistics_name, amount_minor, currency, delivery_min_days,
         delivery_max_days, quoted_at, expires_at, created_at, updated_at)
      VALUES
        (#{validation_id}, #{supplier_id}, #{provider_ref_ciphertext ? q(provider_ref_ciphertext) : "NULL"},
         #{provider_ref_digest ? bytea(provider_ref_digest) : "NULL"}, #{provider_ref_digest ? 1 : "NULL"},
         #{q(warehouse_external_id)}, #{q(logistics_id)}, #{q(logistics_name)}, #{amount_minor}, #{q(currency)},
         #{delivery_min_days || "NULL"}, #{delivery_max_days || "NULL"}, #{q(quoted_at)}, #{q(expires_at)},
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def checkout_intent_insert_sql(cart_id:, intent_key:, hash:, execution_mode: "fixture", provider: "stripe",
                                  status: "open", started_at: reference_time, expires_at: reference_time + 3600,
                                  completed_at: nil, blocked_reason: nil)
    <<~SQL.squish
      INSERT INTO checkout_intents
        (execution_mode, cart_id, provider, intent_key, request_hash, status, blocked_reason,
         started_at, completed_at, expires_at, created_at, updated_at)
      VALUES
        (#{q(execution_mode)}, #{cart_id}, #{q(provider)}, #{q(intent_key)}, #{bytea(hash)}, #{q(status)},
         #{blocked_reason ? q(blocked_reason) : "NULL"}, #{q(started_at)}, #{completed_at ? q(completed_at) : "NULL"},
         #{q(expires_at)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_checkout_intent(**kwargs)
    insert_returning(checkout_intent_insert_sql(**kwargs))
  end
end
