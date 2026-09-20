module Nudge
  module DatabaseCompatibility
    POSTGRESQL_MAJOR = 18
    PGVECTOR_VERSION = "0.8.5"
    PGVECTOR_STRUCTURE_STATEMENT =
      "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public VERSION '#{PGVECTOR_VERSION}';"

    class IncompatibleDatabaseError < StandardError; end

    module_function

    def verify!(connection)
      verify_postgresql!(connection)
      verify_pgvector!(connection)
      true
    end

    def verify_postgresql!(connection)
      server_version_num = connection.select_value("SHOW server_version_num").to_i
      actual_major = server_version_num / 10_000
      return if actual_major == POSTGRESQL_MAJOR

      raise IncompatibleDatabaseError,
        "PostgreSQL #{POSTGRESQL_MAJOR} is required; server_version_num=#{server_version_num}"
    end

    def verify_pgvector!(connection)
      actual_version = pgvector_version(connection)
      return if actual_version == PGVECTOR_VERSION

      actual = actual_version || "not installed"
      raise IncompatibleDatabaseError,
        "pgvector #{PGVECTOR_VERSION} is required; found #{actual}"
    end

    def verify_pgvector_if_installed!(connection)
      actual_version = pgvector_version(connection)
      return if actual_version.nil? || actual_version == PGVECTOR_VERSION

      raise IncompatibleDatabaseError,
        "pgvector #{PGVECTOR_VERSION} is required; found #{actual_version}"
    end

    def pgvector_version(connection)
      connection.select_value(<<~SQL.squish)
        SELECT extversion
        FROM pg_extension
        WHERE extname = 'vector'
      SQL
    end

    def pin_pgvector_structure!(path)
      structure = File.read(path)
      extension_statement = /^CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public(?: VERSION '[^']+')?;$/
      raise "Canonical SQL structure is missing the vector extension" unless structure.match?(extension_statement)

      pinned_structure = structure.sub(extension_statement, PGVECTOR_STRUCTURE_STATEMENT).sub(/\n+\z/, "\n")
      File.write(path, pinned_structure) unless pinned_structure == structure
      true
    end
  end
end
