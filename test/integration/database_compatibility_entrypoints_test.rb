require "test_helper"
require "open3"
require "pg"
require "securerandom"
require "socket"

class DatabaseCompatibilityEntrypointsTest < ActiveSupport::TestCase
  MIGRATION_VERSIONS = Rails.root.glob("db/migrate/*.rb").map { |path| path.basename.to_s.split("_").first }.freeze
  IDENTITY_MIGRATION_VERSION = "20260920000002"
  CATALOG_MIGRATION_VERSION = "20260920000003"
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

  test "catalog migration rolls back completely and preserves its constraints through redo and schema load" do
    with_database do |database, connection|
      Tempfile.create([ "db03-rollback", ".sql" ]) do |structure|
        assert_command_succeeds run_rails(database, "db:migrate", schema: structure.path)

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
        CATALOG_TABLES.each do |table|
          assert_equal table, connection.exec_params("SELECT to_regclass($1)::text", [ "public.#{table}" ]).getvalue(0, 0)
        end
        deferred = connection.exec(<<~SQL).first
          SELECT condeferrable, condeferred
          FROM pg_constraint
          WHERE conname = 'fk_products_primary_category_membership'
        SQL
        assert_equal({ "condeferrable" => "t", "condeferred" => "t" }, deferred)

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
        end
      end
    end
  end

  test "identity migration rolls back completely and recreates its canonical schema on redo" do
    with_database do |database, connection|
      Tempfile.create([ "db02-rollback", ".sql" ]) do |structure|
        assert_command_succeeds run_rails(database, "db:migrate", schema: structure.path)

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
