require "test_helper"
require "open3"
require "pg"
require "securerandom"
require "socket"

class DatabaseCompatibilityEntrypointsTest < ActiveSupport::TestCase
  MIGRATION_VERSIONS = Rails.root.glob("db/migrate/*.rb").map { |path| path.basename.to_s.split("_").first }.freeze
  IDENTITY_MIGRATION_VERSION = "20260920000002"
  CATALOG_MIGRATION_VERSION = "20260920000003"
  CATALOG_EVIDENCE_MIGRATION_VERSION = "20260920000004"
  SEARCH_MIGRATION_VERSION = "20260920000005"
  IDENTITY_TABLES = %w[
    agent_provider_sessions
    ai_access_grants
    turnstile_verifications
    consent_records
    shopping_sessions
    external_identities
    users
  ].freeze
  CATALOG_TABLES = %w[
    supplier_warehouses
    supplier_variants
    supplier_products
    product_variants
    product_categories
    products
    categories
    suppliers
  ].freeze
  CATALOG_EVIDENCE_TABLES = %w[
    supplier_observations catalog_media fact_definitions product_facts
    price_observations inventory_observations sync_runs sync_checkpoints
    supplier_subscriptions
  ].freeze
  SEARCH_TABLES = %w[search_documents embedding_models embeddings].freeze

  SHOPPING_DECISIONS_MIGRATION_VERSION = Rails.root.glob("db/migrate/*.rb")
    .find { |path| path.read.match?(/create_table\s+:?"?shopping_messages"?/) }
    &.basename&.to_s&.split("_")&.first
  SHOPPING_DECISIONS_TABLES = %w[
    agent_tool_calls agent_runs recommendation_evidence eligibility_results
    recommendation_candidates recommendation_runs clarification_decisions
    requirements shopping_messages
  ].freeze

  test "shopping decisions migration rolls back cleanly and survives redo and structure load" do
    assert SHOPPING_DECISIONS_MIGRATION_VERSION, "Expected a DB-06 migration file that creates the shopping_messages table"

    with_database do |database, connection|
      Tempfile.create([ "db06-rollback", ".sql" ]) do |structure|
        assert_command_succeeds run_rails(database, "db:migrate", schema: structure.path)
        assert_command_succeeds run_rails(database, "db:migrate:down", "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}", schema: structure.path)

        SHOPPING_DECISIONS_TABLES.each do |table|
          assert_nil connection.exec_params("SELECT to_regclass($1)", [ "public.#{table}" ]).getvalue(0, 0), table
        end
        CATALOG_EVIDENCE_TABLES.each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end

        assert_command_succeeds run_rails(database, "db:migrate:redo", "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}", schema: structure.path)
        SHOPPING_DECISIONS_TABLES.each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end

        assert_command_succeeds run_rails(database, "db:schema:dump", schema: structure.path)
        dumped = File.read(structure.path)
        assert_includes dumped, Nudge::DatabaseCompatibility::PGVECTOR_STRUCTURE_STATEMENT
        SHOPPING_DECISIONS_TABLES.each { |table| assert_includes dumped, table }

        with_database do |load_database, load_connection|
          assert_command_succeeds run_rails(load_database, "db:schema:load", schema: structure.path)
          SHOPPING_DECISIONS_TABLES.each do |table|
            assert_equal table, load_connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
          end
          assert_equal "0.8.5", load_connection.exec(<<~SQL).getvalue(0, 0)
            SELECT extversion FROM pg_extension WHERE extname = 'vector'
          SQL
        end
      end
    end
  end

  test "catalog evidence migration rolls back cleanly and survives redo and structure load" do
    with_database do |database, connection|
      Tempfile.create([ "db04-rollback", ".sql" ]) do |structure|
        assert_command_succeeds run_rails(database, "db:migrate", schema: structure.path)
        # DB-06 adds foreign keys into product_facts/price_observations/inventory_observations/
        # supplier_observations, so it must be rolled back before DB-04 can drop those tables.
        assert_command_succeeds run_rails(database, "db:migrate:down", "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}", schema: structure.path)
        assert_command_succeeds run_rails(database, "db:migrate:down", "VERSION=#{CATALOG_EVIDENCE_MIGRATION_VERSION}", schema: structure.path)

        CATALOG_EVIDENCE_TABLES.each do |table|
          assert_nil connection.exec_params("SELECT to_regclass($1)", [ "public.#{table}" ]).getvalue(0, 0), table
        end
        %w[supplier_products supplier_variants supplier_warehouses].each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end
        assert_equal %w[latest_observation_id], connection.exec(<<~SQL).map { |row| row.fetch("column_name") }.uniq
          SELECT column_name FROM information_schema.columns
          WHERE table_schema='public' AND table_name IN ('supplier_products','supplier_variants')
            AND column_name='latest_observation_id'
        SQL

        assert_command_succeeds run_rails(database, "db:migrate:redo", "VERSION=#{CATALOG_EVIDENCE_MIGRATION_VERSION}", schema: structure.path)
        assert_command_succeeds run_rails(database, "db:migrate:up", "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}", schema: structure.path)
        CATALOG_EVIDENCE_TABLES.each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end
        assert_equal "2", connection.exec(<<~SQL).getvalue(0, 0)
          SELECT count(*) FROM pg_constraint
          WHERE conname IN ('fk_supplier_products_latest_observation','fk_supplier_variants_latest_observation')
            AND convalidated
        SQL
        assert_db04_schema_version_guards connection

        assert_command_succeeds run_rails(database, "db:schema:dump", schema: structure.path)
        dumped = File.read(structure.path)
        assert_includes dumped, Nudge::DatabaseCompatibility::PGVECTOR_STRUCTURE_STATEMENT
        assert_includes dumped, "db04_supplier_observation_guard"
        assert_includes dumped, "fk_supplier_products_latest_observation"

        with_database do |load_database, load_connection|
          assert_command_succeeds run_rails(load_database, "db:schema:load", schema: structure.path)
          CATALOG_EVIDENCE_TABLES.each do |table|
            assert_equal table, load_connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
          end
          assert_equal "0.8.5", load_connection.exec("SELECT extversion FROM pg_extension WHERE extname='vector'").getvalue(0, 0)
          assert_equal "2", load_connection.exec(<<~SQL).getvalue(0, 0)
            SELECT count(*) FROM pg_proc
            WHERE proname IN ('db04_supplier_observation_guard','db04_product_fact_validate')
              AND prosecdef = false
              AND proconfig = ARRAY['search_path=pg_catalog']
          SQL
          assert_db04_schema_version_guards load_connection
        end
      end
    end
  end

  test "search and vector migration rolls back cleanly, redoes, and survives structure load without an approximate vector index" do
    with_database do |database, connection|
      Tempfile.create([ "db05-rollback", ".sql" ]) do |structure|
        assert_command_succeeds run_rails(database, "db:migrate", schema: structure.path)
        assert_command_succeeds run_rails(database, "db:migrate:down", "VERSION=#{SEARCH_MIGRATION_VERSION}", schema: structure.path)

        SEARCH_TABLES.each do |table|
          assert_nil connection.exec_params("SELECT to_regclass($1)", [ "public.#{table}" ]).getvalue(0, 0), table
        end
        %w[products product_variants].each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end

        assert_command_succeeds run_rails(database, "db:migrate:redo", "VERSION=#{SEARCH_MIGRATION_VERSION}", schema: structure.path)
        SEARCH_TABLES.each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end
        assert_no_approximate_vector_index(connection)
        assert_equal "1", connection.exec_params(<<~SQL).getvalue(0, 0)
          SELECT count(*) FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'search_documents'
            AND column_name = 'search_vector' AND is_generated = 'ALWAYS'
        SQL

        assert_command_succeeds run_rails(database, "db:schema:dump", schema: structure.path)
        dumped = File.read(structure.path)
        assert_includes dumped, Nudge::DatabaseCompatibility::PGVECTOR_STRUCTURE_STATEMENT
        assert_includes dumped, "GENERATED ALWAYS AS (to_tsvector('english'::regconfig, normalized_text)) STORED"
        assert_includes dumped, "index_embeddings_one_active_per_document_model"
        refute_match(/USING (hnsw|ivfflat)/i, dumped)

        with_database do |load_database, load_connection|
          assert_command_succeeds run_rails(load_database, "db:schema:load", schema: structure.path)
          SEARCH_TABLES.each do |table|
            assert_equal table, load_connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
          end
          assert_equal "0.8.5", load_connection.exec(<<~SQL).getvalue(0, 0)
            SELECT extversion FROM pg_extension WHERE extname = 'vector'
          SQL
          assert_no_approximate_vector_index(load_connection)
        end
      end
    end
  end

  test "catalog migration rolls back completely and preserves its constraints through redo and schema load" do
    with_database do |database, connection|
      Tempfile.create([ "db03-rollback", ".sql" ]) do |structure|
        assert_command_succeeds run_rails(database, "db:migrate", schema: structure.path)
        # DB-06 adds foreign keys into products/product_variants (via recommendation_candidates)
        # and into DB-04's catalog evidence tables, so it must roll back before either does.
        assert_command_succeeds run_rails(
          database,
          "db:migrate:down",
          "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}",
          schema: structure.path
        )
        assert_command_succeeds run_rails(
          database,
          "db:migrate:down",
          "VERSION=#{CATALOG_EVIDENCE_MIGRATION_VERSION}",
          schema: structure.path
        )
        assert_command_succeeds run_rails(
          database,
          "db:migrate:down",
          "VERSION=#{SEARCH_MIGRATION_VERSION}",
          schema: structure.path
        )

        assert_command_succeeds run_rails(
          database,
          "db:migrate:down",
          "VERSION=#{CATALOG_MIGRATION_VERSION}",
          schema: structure.path
        )
        CATALOG_TABLES.each do |table|
          assert_nil connection.exec_params("SELECT to_regclass($1)", [ "public.#{table}" ]).getvalue(0, 0), table
        end
        assert_equal "0", connection.exec_params(<<~SQL).getvalue(0, 0)
          SELECT count(*)
          FROM pg_constraint
          WHERE conname = 'fk_products_primary_category_membership'
             OR conname = 'fk_supplier_variants_product_supplier'
        SQL

        assert_command_succeeds run_rails(
          database,
          "db:migrate:redo",
          "VERSION=#{CATALOG_MIGRATION_VERSION}",
          schema: structure.path
        )
        assert_command_succeeds run_rails(
          database,
          "db:migrate:up",
          "VERSION=#{CATALOG_EVIDENCE_MIGRATION_VERSION}",
          schema: structure.path
        )
        assert_command_succeeds run_rails(
          database,
          "db:migrate:up",
          "VERSION=#{SEARCH_MIGRATION_VERSION}",
          schema: structure.path
        )
        assert_command_succeeds run_rails(
          database,
          "db:migrate:up",
          "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}",
          schema: structure.path
        )
        CATALOG_TABLES.each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end
        deferred = connection.exec(<<~SQL).first
          SELECT condeferrable, condeferred
          FROM pg_constraint
          WHERE conname = 'fk_products_primary_category_membership'
        SQL
        assert_equal({ "condeferrable" => "t", "condeferred" => "t" }, deferred)
        assert_measurement_nan_guards connection

        assert_command_succeeds run_rails(database, "db:schema:dump", schema: structure.path)
        dumped = File.read(structure.path)
        assert_includes dumped, Nudge::DatabaseCompatibility::PGVECTOR_STRUCTURE_STATEMENT
        assert_includes dumped, "fk_products_primary_category_membership"

        with_database do |load_database, load_connection|
          assert_command_succeeds run_rails(load_database, "db:schema:load", schema: structure.path)
          CATALOG_TABLES.each do |table|
            assert_equal table, load_connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
          end
          assert_equal "0.8.5", load_connection.exec(<<~SQL).getvalue(0, 0)
            SELECT extversion FROM pg_extension WHERE extname = 'vector'
          SQL
          assert_equal "true", load_connection.exec(<<~SQL).getvalue(0, 0)
            SELECT condeferrable::text
            FROM pg_constraint
            WHERE conname = 'fk_products_primary_category_membership'
          SQL
          assert_measurement_nan_guards load_connection
        end
      end
    end
  end

  test "identity migration rolls back completely and recreates its canonical schema on redo" do
    with_database do |database, connection|
      Tempfile.create([ "db02-rollback", ".sql" ]) do |structure|
        assert_command_succeeds run_rails(database, "db:migrate", schema: structure.path)

        # DB-06's agent_runs has composite foreign keys into ai_access_grants and
        # agent_provider_sessions, so it must roll back before DB-02 can drop those tables.
        assert_command_succeeds run_rails(
          database,
          "db:migrate:down",
          "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}",
          schema: structure.path
        )
        assert_command_succeeds run_rails(
          database,
          "db:migrate:down",
          "VERSION=#{IDENTITY_MIGRATION_VERSION}",
          schema: structure.path
        )
        IDENTITY_TABLES.each do |table|
          assert_nil connection.exec_params("SELECT to_regclass($1)", [ "public.#{table}" ]).getvalue(0, 0), table
        end
        assert_equal "0", connection.exec_params(<<~SQL).getvalue(0, 0)
          SELECT count(*)
          FROM pg_constraint
          WHERE conname LIKE 'fk_ai_grants_%'
             OR conname LIKE 'fk_agent_provider_sessions_%'
        SQL

        assert_command_succeeds run_rails(
          database,
          "db:migrate:redo",
          "VERSION=#{IDENTITY_MIGRATION_VERSION}",
          schema: structure.path
        )
        assert_command_succeeds run_rails(
          database,
          "db:migrate:up",
          "VERSION=#{SHOPPING_DECISIONS_MIGRATION_VERSION}",
          schema: structure.path
        )
        IDENTITY_TABLES.each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end
        assert_equal "1", connection.exec_params(<<~SQL).getvalue(0, 0)
          SELECT count(*)
          FROM pg_constraint
          WHERE conname = 'fk_ai_grants_turnstile_session'
        SQL

        assert_command_succeeds run_rails(database, "db:schema:dump", schema: structure.path)
        assert_includes File.read(structure.path), Nudge::DatabaseCompatibility::PGVECTOR_STRUCTURE_STATEMENT

        with_database do |load_database, load_connection|
          assert_command_succeeds run_rails(load_database, "db:schema:load", schema: structure.path)
          IDENTITY_TABLES.each do |table|
            assert_equal table, load_connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
          end
          assert_equal "0.8.5", load_connection.exec(<<~SQL).getvalue(0, 0)
            SELECT extversion FROM pg_extension WHERE extname = 'vector'
          SQL
        end
      end
    end
  end

  test "schema load rejects an existing wrong pgvector version before stamping the migration" do
    with_database do |database, connection|
      install_vector_as(connection, "0.8.4")

      stdout, stderr, status = run_rails(database, "db:schema:load")

      refute_predicate status, :success?
      assert_includes stdout + stderr, "pgvector 0.8.5 is required; found 0.8.4"
      assert_nil connection.exec_params("SELECT to_regclass($1)", [ "public.schema_migrations" ]).getvalue(0, 0)
    end
  end

  test "prepare rejects an already migrated database without pgvector" do
    with_database do |database, connection|
      stamp_migration(connection)

      stdout, stderr, status = run_rails(database, "db:prepare")

      refute_predicate status, :success?
      assert_includes stdout + stderr, "pgvector 0.8.5 is required; found not installed"
    end
  end

  test "prepare rejects an already migrated database with the wrong pgvector version" do
    with_database do |database, connection|
      install_vector_as(connection, "0.8.4")
      stamp_migration(connection)

      stdout, stderr, status = run_rails(database, "db:prepare")

      refute_predicate status, :success?
      assert_includes stdout + stderr, "pgvector 0.8.5 is required; found 0.8.4"
    end
  end

  test "production entrypoint rejects absent and wrong pgvector before starting Rails" do
    with_database do |database, connection|
      output, status = run_entrypoint(database)
      refute_predicate status, :success?
      assert_includes output, "pgvector 0.8.5 is required; found not installed"
      refute_includes output, "Listening on"

      install_vector_as(connection, "0.8.4")
      output, status = run_entrypoint(database)
      refute_predicate status, :success?
      assert_includes output, "pgvector 0.8.5 is required; found 0.8.4"
      refute_includes output, "Listening on"
    end
  end

  test "production entrypoint rejects the wrong PostgreSQL major before starting Rails" do
    with_database do |database, connection|
      install_vector_as(connection, "0.8.5")

      with_server_version_proxy("170011") do |port|
        output, status = run_entrypoint(database, host: "127.0.0.1", port:)

        refute_predicate status, :success?
        assert_includes output, "PostgreSQL 18 is required; server_version_num=170011"
        refute_includes output, "Listening on"
      end
    end
  end

  private

  def assert_db04_schema_version_guards(connection)
    [ "NULL", "0" ].each_with_index do |version, index|
      assert_raises(PG::CheckViolation) do
        connection.exec(<<~SQL)
          INSERT INTO fact_definitions
            (key,label,data_type,allowed_operators,allowed_operators_schema_version,allowed_values_schema,
             allowed_values_schema_version,hard_eligibility_supported,version,status,created_at,updated_at)
          VALUES ('invalid-enum-#{index}','Enum','enum','[]',1,'{"enum":[""]}',#{version},false,1,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
        SQL
      end
    end
    connection.exec(<<~SQL)
      INSERT INTO fact_definitions
        (key,label,data_type,allowed_operators,allowed_operators_schema_version,allowed_values_schema,
         allowed_values_schema_version,hard_eligibility_supported,version,status,created_at,updated_at)
      VALUES ('valid-enum','Enum','enum','[]',1,'{"enum":[""]}',1,false,1,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
    SQL

    product_id = connection.exec(<<~SQL).getvalue(0, 0)
      INSERT INTO products (status,title,description,lock_version,created_at,updated_at)
      VALUES ('draft','Version guard','',0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING id
    SQL
    definition_id = connection.exec(<<~SQL).getvalue(0, 0)
      INSERT INTO fact_definitions
        (key,label,data_type,allowed_operators,allowed_operators_schema_version,hard_eligibility_supported,version,status,created_at,updated_at)
      VALUES ('json-guard','JSON','json','[]',1,false,1,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) RETURNING id
    SQL
    [ "NULL", "0" ].each do |version|
      assert_raises(PG::CheckViolation) do
        connection.exec(<<~SQL)
          INSERT INTO product_facts
            (product_id,fact_definition_id,json_value,value_schema_version,source_kind,observed_at,status,created_at,updated_at)
          VALUES (#{product_id},#{definition_id},'{}',#{version},'manual',CURRENT_TIMESTAMP,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
        SQL
      end
    end
    connection.exec(<<~SQL)
      INSERT INTO product_facts
        (product_id,fact_definition_id,json_value,value_schema_version,source_kind,observed_at,status,created_at,updated_at)
      VALUES (#{product_id},#{definition_id},'{}',1,'manual',CURRENT_TIMESTAMP,'active',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)
    SQL
  end

  def assert_no_approximate_vector_index(connection)
    count = connection.exec_params(<<~SQL).getvalue(0, 0)
      SELECT count(*)
      FROM pg_indexes
      WHERE schemaname = 'public' AND tablename = 'embeddings'
        AND (indexdef ILIKE '%USING hnsw%' OR indexdef ILIKE '%USING ivfflat%')
    SQL
    assert_equal "0", count
  end

  def assert_measurement_nan_guards(connection)
    %w[
      product_variants_measurements_nonnegative_check
      supplier_variants_measurements_nonnegative_check
    ].each do |constraint|
      definition = connection.exec_params(<<~SQL, [ constraint ]).getvalue(0, 0)
        SELECT pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conname = $1
      SQL
      assert_includes definition, "<> 'NaN'::numeric", constraint
    end
  end

  def with_database
    database = "nudge_db01_#{SecureRandom.hex(6)}_test"
    admin = postgres_connection("postgres")
    admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(database)}")
    connection = postgres_connection(database)
    yield database, connection
  ensure
    connection&.close
    if admin && database
      admin.exec_params(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = $1 AND pid <> pg_backend_pid()",
        [ database ]
      )
      admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(database)}")
    end
    admin&.close
  end

  def postgres_connection(database)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(
      host: config.fetch(:host),
      port: config.fetch(:port),
      user: config.fetch(:username),
      password: config.fetch(:password),
      dbname: database
    )
  end

  def install_vector_as(connection, version)
    connection.exec("CREATE EXTENSION vector WITH SCHEMA public VERSION '0.8.5'")
    connection.exec_params("UPDATE pg_extension SET extversion = $1 WHERE extname = 'vector'", [ version ])
  end

  def stamp_migration(connection)
    connection.exec("CREATE TABLE schema_migrations (version character varying PRIMARY KEY)")
    MIGRATION_VERSIONS.each do |version|
      connection.exec_params("INSERT INTO schema_migrations (version) VALUES ($1)", [ version ])
    end
  end

  def run_rails(database, *arguments, schema: nil)
    environment = command_environment(database)
    environment["SCHEMA"] = schema if schema
    Open3.capture3(environment, Rails.root.join("bin/rails").to_s, *arguments)
  end

  def assert_command_succeeds(result)
    stdout, stderr, status = result
    assert_predicate status, :success?, stdout + stderr
  end

  def run_entrypoint(database, host: nil, port: nil)
    stdout, stderr, status = Open3.capture3(
      command_environment(database, host:, port:).merge("RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1"),
      Rails.root.join("bin/docker-entrypoint").to_s,
      "bin/rails",
      "server"
    )
    [ stdout + stderr, status ]
  end

  def command_environment(database, host: nil, port: nil)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    database_host = host || config.fetch(:host)
    database_port = port || config.fetch(:port)
    {
      "RAILS_ENV" => "test",
      "DATABASE_URL" => "postgresql://#{database_host}:#{database_port}/#{database}?sslmode=disable",
      "DB_USER" => config.fetch(:username),
      "DB_PASSWORD" => config.fetch(:password),
      "PROVIDER_MODE" => "fixture",
      "CJ_MODE" => "fixture"
    }
  end

  def with_server_version_proxy(reported_version)
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    expected_version = connection_server_version
    server = TCPServer.new("127.0.0.1", 0)
    proxy = Thread.new do
      client = server.accept
      upstream = TCPSocket.new(config.fetch(:host), config.fetch(:port))
      request = Thread.new { IO.copy_stream(client, upstream) }
      response = Thread.new { rewrite_server_version(upstream, client, expected_version, reported_version) }
      request.join
      response.join
    ensure
      client&.close
      upstream&.close
    end

    yield server.local_address.ip_port
  ensure
    server&.close
    proxy&.kill
    proxy&.join
  end

  def rewrite_server_version(source, destination, expected_version, reported_version)
    loop do
      header = source.read(5)
      break unless header&.bytesize == 5

      payload_length = header.byteslice(1, 4).unpack1("N") - 4
      payload = source.read(payload_length)
      destination.write(header)
      destination.write(payload.gsub(expected_version, reported_version))
    end
  rescue IOError, Errno::ECONNRESET
    nil
  end

  def connection_server_version
    ActiveRecord::Base.connection.select_value("SHOW server_version_num")
  end
end
