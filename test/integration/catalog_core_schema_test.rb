require "test_helper"
require "pg"

class CatalogCoreSchemaTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  TABLES = %w[
    supplier_warehouses
    supplier_variants
    supplier_products
    product_variants
    product_categories
    products
    categories
    suppliers
  ].freeze

  setup { truncate_catalog_tables }
  teardown { truncate_catalog_tables }

  test "creates the exact catalog core columns without redundant primary state" do
    expected = {
      "suppliers" => %w[id key display_name adapter_version api_version status created_at updated_at],
      "categories" => %w[id public_id key name parent_id status position profile_version created_at updated_at],
      "products" => %w[id public_id status title description product_type brand primary_category_id published_at retired_at lock_version created_at updated_at],
      "product_categories" => %w[id product_id category_id provenance created_at updated_at],
      "product_variants" => %w[id public_id product_id canonical_sku title option_summary option_schema_version status weight_value weight_unit length_value width_value height_value dimension_unit lock_version created_at updated_at],
      "supplier_products" => %w[id supplier_id product_id external_product_id external_sku external_category_id status first_seen_at last_seen_at last_synced_at adapter_version latest_observation_id created_at updated_at],
      "supplier_variants" => %w[id supplier_id product_variant_id supplier_product_id external_variant_id external_variant_sku barcode weight_value weight_unit length_value width_value height_value dimension_unit status first_seen_at last_seen_at last_synced_at latest_observation_id created_at updated_at],
      "supplier_warehouses" => %w[id supplier_id external_warehouse_id country_code region_code name verification_state status first_seen_at last_seen_at created_at updated_at]
    }

    expected.each do |table, columns|
      assert_equal columns.sort, connection.columns(table).map(&:name).sort, table
    end
    refute_includes connection.columns("product_categories").map(&:name), "is_primary"
  end

  test "uses canonical defaults, PostgreSQL types, and bounded mutable metadata" do
    %w[categories products product_variants].each do |table|
      assert_match(/gen_random_uuid/, column_default(table, "public_id"))
    end

    TABLES.each do |table|
      timestamp_columns(table).each do |column|
        assert_equal "timestamp with time zone", column.fetch("data_type"), "#{table}.#{column.fetch("column_name")}"
      end
    end

    assert_equal [ 14, 4 ], numeric_shape("product_variants", "weight_value")
    assert_equal [ 14, 4 ], numeric_shape("supplier_variants", "length_value")

    product_id = insert_product
    variant_id = insert_product_variant(product_id: product_id)
    assert_constraint { execute("UPDATE products SET lock_version = -1 WHERE id = #{product_id}") }
    assert_constraint { execute("UPDATE product_variants SET lock_version = -1 WHERE id = #{variant_id}") }
    assert_constraint { insert_category(profile_version: -1) }
    assert_constraint { insert_product_variant(product_id: product_id, option_schema_version: 0, sku: "bad-version") }
    assert_constraint do
      execute <<~SQL
        UPDATE product_variants SET option_summary = '[]'::jsonb WHERE id = #{variant_id}
      SQL
    end
  end

  test "enforces category hierarchy and product lifecycle checks" do
    category_id = insert_category
    assert_constraint { execute("UPDATE categories SET parent_id = id WHERE id = #{category_id}") }
    assert_constraint(unique: true) { insert_category(key: "category") }

    assert_constraint { insert_product(status: "unknown") }
    assert_constraint { insert_product(status: "retired", retired_at: nil) }
    assert_constraint { insert_product(status: "active", retired_at: reference_time) }
    assert_constraint do
      insert_product(status: "retired", published_at: reference_time, retired_at: reference_time - 1)
    end
    assert insert_product(status: "retired", published_at: reference_time, retired_at: reference_time + 1)
  end

  test "allows zero or one primary category and defers same-product membership until commit" do
    category_id = insert_category
    other_category_id = insert_category(key: "other")
    product_id = insert_product
    other_product_id = insert_product(title: "Other")

    connection.transaction do
      execute("UPDATE products SET primary_category_id = #{category_id} WHERE id = #{product_id}")
      execute <<~SQL
        INSERT INTO product_categories (product_id, category_id, provenance, created_at, updated_at)
        VALUES (#{product_id}, #{category_id}, 'manual', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      SQL
    end
    assert_equal category_id, select_value("SELECT primary_category_id FROM products WHERE id = #{product_id}").to_i

    error = assert_raises(ActiveRecord::StatementInvalid) do
      connection.transaction do
        execute <<~SQL
          INSERT INTO product_categories (product_id, category_id, provenance, created_at, updated_at)
          VALUES (#{other_product_id}, #{other_category_id}, 'manual', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
        execute("UPDATE products SET primary_category_id = #{other_category_id} WHERE id = #{product_id}")
      end
    end
    assert_kind_of PG::ForeignKeyViolation, error.cause

    assert_constraint(foreign_key: true) do
      execute("DELETE FROM product_categories WHERE product_id = #{product_id} AND category_id = #{category_id}")
    end
    execute("UPDATE products SET primary_category_id = NULL WHERE id = #{product_id}")
    assert_nil select_value("SELECT primary_category_id FROM products WHERE id = #{product_id}")
  end

  test "enforces canonical variant measurement and unit predicates" do
    product_id = insert_product

    assert_constraint { insert_product_variant(product_id: product_id, sku: "negative", weight_value: -1, weight_unit: "g") }
    assert_constraint { insert_product_variant(product_id: product_id, sku: "weight-only", weight_value: 1) }
    assert_constraint { insert_product_variant(product_id: product_id, sku: "unit-only", weight_unit: "g") }
    assert_constraint { insert_product_variant(product_id: product_id, sku: "dimension-only", length_value: 1) }
    assert_constraint { insert_product_variant(product_id: product_id, sku: "dimension-unit-only", dimension_unit: "cm") }
    assert insert_product_variant(product_id: product_id, sku: "partial-dimensions", length_value: 1, dimension_unit: "cm")
    assert insert_product_variant(
      product_id: product_id,
      sku: "zero-measurements",
      weight_value: 0,
      weight_unit: "g",
      length_value: 0,
      width_value: 0,
      height_value: 0,
      dimension_unit: "cm"
    )
  end

  test "rejects NaN in every canonical and supplier measurement column" do
    product_id = insert_product
    product_variant_id = insert_product_variant(
      product_id: product_id,
      weight_value: 1,
      weight_unit: "g",
      length_value: 1,
      width_value: 2,
      height_value: 3,
      dimension_unit: "cm"
    )

    %w[weight_value length_value width_value height_value].each do |column|
      assert_constraint { execute("UPDATE product_variants SET #{column} = 'NaN'::numeric WHERE id = #{product_variant_id}") }
    end

    supplier_id = insert_supplier
    supplier_product_id = insert_supplier_product(supplier_id: supplier_id, product_id: product_id)
    supplier_variant_id = insert_supplier_variant(
      supplier_id: supplier_id,
      product_variant_id: product_variant_id,
      supplier_product_id: supplier_product_id,
      weight_value: 1,
      weight_unit: "g",
      length_value: 1,
      width_value: 2,
      height_value: 3,
      dimension_unit: "cm"
    )

    %w[weight_value length_value width_value height_value].each do |column|
      assert_constraint { execute("UPDATE supplier_variants SET #{column} = 'NaN'::numeric WHERE id = #{supplier_variant_id}") }
    end
  end

  test "keeps supplier identifiers scoped, opaque, and race safe" do
    supplier_id = insert_supplier
    product_id = insert_product
    second_product_id = insert_product(title: "Second")
    first_seen = reference_time

    statements = [ product_id, second_product_id ].map do |candidate_product_id|
      supplier_product_sql(
        supplier_id: supplier_id,
        product_id: candidate_product_id,
        external_product_id: "opaque/id:with punctuation",
        first_seen_at: first_seen
      )
    end
    results = concurrent_statements(statements)
    assert_equal 1, results.count(:inserted)
    assert_equal 1, results.count { |result| result == PG::UniqueViolation }

    other_supplier_id = insert_supplier(key: "other")
    assert insert_supplier_product(
      supplier_id: other_supplier_id,
      product_id: second_product_id,
      external_product_id: "opaque/id:with punctuation",
      first_seen_at: first_seen
    )
  end

  test "enforces supplier ownership, measurements, and temporal bounds" do
    supplier_id = insert_supplier
    other_supplier_id = insert_supplier(key: "other")
    product_id = insert_product
    variant_id = insert_product_variant(product_id: product_id)
    supplier_product_id = insert_supplier_product(supplier_id: supplier_id, product_id: product_id)

    assert_constraint do
      insert_supplier_product(supplier_id: supplier_id, product_id: insert_product(title: "Late"), external_product_id: "late", last_seen_at: reference_time - 1)
    end
    assert_constraint do
      insert_supplier_product(supplier_id: supplier_id, product_id: insert_product(title: "Sync"), external_product_id: "sync", last_synced_at: reference_time - 1)
    end
    assert_constraint(foreign_key: true) do
      insert_supplier_variant(
        supplier_id: other_supplier_id,
        product_variant_id: variant_id,
        supplier_product_id: supplier_product_id
      )
    end
    assert_constraint { insert_supplier_variant(supplier_id: supplier_id, product_variant_id: variant_id, supplier_product_id: supplier_product_id, weight_value: 1) }
    assert_constraint { insert_supplier_variant(supplier_id: supplier_id, product_variant_id: variant_id, supplier_product_id: supplier_product_id, length_value: 1) }
    assert_constraint { insert_supplier_variant(supplier_id: supplier_id, product_variant_id: variant_id, supplier_product_id: supplier_product_id, last_seen_at: reference_time - 1) }
    assert_constraint { insert_supplier_variant(supplier_id: supplier_id, product_variant_id: variant_id, supplier_product_id: supplier_product_id, last_synced_at: reference_time - 1) }

    assert insert_supplier_variant(
      supplier_id: supplier_id,
      product_variant_id: variant_id,
      supplier_product_id: supplier_product_id,
      weight_value: 100,
      weight_unit: "g",
      width_value: 2,
      dimension_unit: "cm"
    )

    null_variant_id = insert_product_variant(product_id: product_id, sku: "supplier-null")
    assert insert_supplier_variant(
      supplier_id: supplier_id,
      product_variant_id: null_variant_id,
      supplier_product_id: supplier_product_id,
      external_id: "supplier-null"
    )

    zero_variant_id = insert_product_variant(product_id: product_id, sku: "supplier-zero")
    assert insert_supplier_variant(
      supplier_id: supplier_id,
      product_variant_id: zero_variant_id,
      supplier_product_id: supplier_product_id,
      external_id: "supplier-zero",
      weight_value: 0,
      weight_unit: "g",
      length_value: 0,
      width_value: 0,
      height_value: 0,
      dimension_unit: "cm"
    )
  end

  test "enforces warehouse country and time checks" do
    supplier_id = insert_supplier
    assert insert_supplier_warehouse(supplier_id: supplier_id, external_id: "area/stock:id", country_code: "US")
    assert_constraint { insert_supplier_warehouse(supplier_id: supplier_id, external_id: "lower", country_code: "us") }
    assert_constraint { insert_supplier_warehouse(supplier_id: supplier_id, external_id: "late", last_seen_at: reference_time - 1) }
    assert_constraint(unique: true) { insert_supplier_warehouse(supplier_id: supplier_id, external_id: "area/stock:id") }
  end

  test "applies the approved delete graph" do
    supplier_id = insert_supplier
    category_id = insert_category
    product_id = insert_product
    variant_id = insert_product_variant(product_id: product_id)
    execute <<~SQL
      INSERT INTO product_categories (product_id, category_id, provenance, created_at, updated_at)
      VALUES (#{product_id}, #{category_id}, 'manual', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL

    assert_constraint(foreign_key: true) { execute("DELETE FROM categories WHERE id = #{category_id}") }
    execute("DELETE FROM products WHERE id = #{product_id}")
    assert_equal 0, select_value("SELECT count(*) FROM product_categories").to_i
    assert_equal 0, select_value("SELECT count(*) FROM product_variants WHERE id = #{variant_id}").to_i

    mapped_product_id = insert_product(title: "Mapped")
    insert_supplier_product(supplier_id: supplier_id, product_id: mapped_product_id)
    assert_constraint(foreign_key: true) { execute("DELETE FROM products WHERE id = #{mapped_product_id}") }
    assert_constraint(foreign_key: true) { execute("DELETE FROM suppliers WHERE id = #{supplier_id}") }
  end

  test "indexes latest observations but leaves their DB-04 foreign keys absent" do
    %w[supplier_products supplier_variants].each do |table|
      assert connection.indexes(table).any? { |index| index.columns == [ "latest_observation_id" ] }, table
      foreign_keys = connection.foreign_keys(table).select { |foreign_key| foreign_key.column == "latest_observation_id" }
      assert_empty foreign_keys, table
    end
  end

  private

  def connection = ActiveRecord::Base.connection
  def execute(sql) = connection.execute(sql)
  def select_value(sql) = connection.select_value(sql)
  def q(value) = connection.quote(value)
  def reference_time = Time.utc(2026, 9, 20, 12)

  def insert_returning(sql)
    select_value("#{sql} RETURNING id").to_i
  end

  def insert_supplier(key: "supplier")
    insert_returning <<~SQL.squish
      INSERT INTO suppliers (key, display_name, adapter_version, api_version, status, created_at, updated_at)
      VALUES (#{q(key)}, 'Supplier', 'adapter-v1', 'api-v1', 'active', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_category(key: "category", profile_version: 1)
    insert_returning <<~SQL.squish
      INSERT INTO categories (key, name, status, position, profile_version, created_at, updated_at)
      VALUES (#{q(key)}, 'Category', 'active', 0, #{profile_version}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_product(title: "Product", status: "draft", published_at: nil, retired_at: nil)
    insert_returning <<~SQL.squish
      INSERT INTO products (status, title, published_at, retired_at, created_at, updated_at)
      VALUES (#{q(status)}, #{q(title)}, #{published_at ? q(published_at) : "NULL"}, #{retired_at ? q(retired_at) : "NULL"}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_product_variant(product_id:, sku: "sku", option_schema_version: 1, weight_value: nil, weight_unit: nil, length_value: nil, width_value: nil, height_value: nil, dimension_unit: nil)
    insert_returning <<~SQL.squish
      INSERT INTO product_variants
        (product_id, canonical_sku, title, option_schema_version, weight_value, weight_unit,
         length_value, width_value, height_value, dimension_unit, created_at, updated_at)
      VALUES
        (#{product_id}, #{q(sku)}, 'Variant', #{option_schema_version}, #{weight_value || "NULL"},
         #{weight_unit ? q(weight_unit) : "NULL"}, #{length_value || "NULL"}, #{width_value || "NULL"},
         #{height_value || "NULL"}, #{dimension_unit ? q(dimension_unit) : "NULL"},
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_supplier_product(supplier_id:, product_id:, external_product_id: "product/ref", first_seen_at: reference_time, last_seen_at: reference_time, last_synced_at: nil)
    insert_returning supplier_product_sql(
      supplier_id: supplier_id,
      product_id: product_id,
      external_product_id: external_product_id,
      first_seen_at: first_seen_at,
      last_seen_at: last_seen_at,
      last_synced_at: last_synced_at
    )
  end

  def supplier_product_sql(supplier_id:, product_id:, external_product_id:, first_seen_at:, last_seen_at: first_seen_at, last_synced_at: nil)
    <<~SQL.squish
      INSERT INTO supplier_products
        (supplier_id, product_id, external_product_id, status, first_seen_at, last_seen_at,
         last_synced_at, adapter_version, created_at, updated_at)
      VALUES
        (#{supplier_id}, #{product_id}, #{q(external_product_id)}, 'active', #{q(first_seen_at)},
         #{q(last_seen_at)}, #{last_synced_at ? q(last_synced_at) : "NULL"}, 'adapter-v1',
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_supplier_variant(supplier_id:, product_variant_id:, supplier_product_id:, external_id: "variant/ref", weight_value: nil, weight_unit: nil, length_value: nil, width_value: nil, height_value: nil, dimension_unit: nil, last_seen_at: reference_time, last_synced_at: nil)
    insert_returning <<~SQL.squish
      INSERT INTO supplier_variants
        (supplier_id, product_variant_id, supplier_product_id, external_variant_id, weight_value,
         weight_unit, length_value, width_value, height_value, dimension_unit, status,
         first_seen_at, last_seen_at, last_synced_at, created_at, updated_at)
      VALUES
        (#{supplier_id}, #{product_variant_id}, #{supplier_product_id}, #{q(external_id)},
         #{weight_value || "NULL"}, #{weight_unit ? q(weight_unit) : "NULL"},
         #{length_value || "NULL"}, #{width_value || "NULL"}, #{height_value || "NULL"},
         #{dimension_unit ? q(dimension_unit) : "NULL"}, 'active', #{q(reference_time)},
         #{q(last_seen_at)}, #{last_synced_at ? q(last_synced_at) : "NULL"},
         CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def insert_supplier_warehouse(supplier_id:, external_id:, country_code: nil, last_seen_at: reference_time)
    insert_returning <<~SQL.squish
      INSERT INTO supplier_warehouses
        (supplier_id, external_warehouse_id, country_code, status, first_seen_at, last_seen_at, created_at, updated_at)
      VALUES
        (#{supplier_id}, #{q(external_id)}, #{country_code ? q(country_code) : "NULL"}, 'active',
         #{q(reference_time)}, #{q(last_seen_at)}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
  end

  def assert_constraint(unique: false, foreign_key: false, &block)
    error = assert_raises(ActiveRecord::StatementInvalid, &block)
    assert_kind_of ActiveRecord::RecordNotUnique, error if unique
    if foreign_key
      assert(
        error.is_a?(ActiveRecord::InvalidForeignKey) ||
          error.cause.is_a?(PG::ForeignKeyViolation) ||
          error.cause.is_a?(PG::RestrictViolation),
        "Expected a foreign-key violation, got #{error.class}: #{error.message}"
      )
    end
    error
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
    {
      host: config[:host], port: config[:port], dbname: config[:database],
      user: config[:username], password: config[:password]
    }.compact
  end

  def timestamp_columns(table)
    connection.exec_query(<<~SQL.squish).to_a
      SELECT column_name, data_type FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = #{q(table)} AND data_type LIKE 'timestamp%'
    SQL
  end

  def numeric_shape(table, column)
    row = connection.exec_query(<<~SQL.squish).first
      SELECT numeric_precision, numeric_scale FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = #{q(table)} AND column_name = #{q(column)}
    SQL
    [ row.fetch("numeric_precision"), row.fetch("numeric_scale") ]
  end

  def column_default(table, column)
    select_value(<<~SQL.squish)
      SELECT column_default FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = #{q(table)} AND column_name = #{q(column)}
    SQL
  end

  def truncate_catalog_tables
    existing = TABLES.select { |table| connection.data_source_exists?(table) }
    execute("TRUNCATE TABLE #{existing.join(", ")} RESTART IDENTITY CASCADE") if existing.any?
  end
end
