require "test_helper"
require "erb"
require "open3"

class RuntimeContractTest < ActiveSupport::TestCase
  test "application commands run as a non-root user" do
    refute_equal 0, Process.uid
  end

  test "ordinary tests use fixture-only provider mode" do
    assert_equal "fixture", ENV.fetch("PROVIDER_MODE")
    assert_equal "fixture", ENV.fetch("CJ_MODE")
  end

  test "development and test databases have distinct names" do
    configurations = ActiveRecord::Base.configurations
    development = configurations.configs_for(env_name: "development", name: "primary")
    test = configurations.configs_for(env_name: "test", name: "primary")

    refute_equal development.database, test.database
    assert_equal ActiveRecord::Base.connection_db_config.database, test.database
  end

  test "database configuration rejects identical development and test names" do
    previous_development = ENV["DEVELOPMENT_DATABASE_NAME"]
    previous_test = ENV["TEST_DATABASE_NAME"]
    ENV["DEVELOPMENT_DATABASE_NAME"] = "nudge_shared"
    ENV["TEST_DATABASE_NAME"] = "nudge_shared"

    error = assert_raises(RuntimeError) do
      ERB.new(Rails.root.join("config/database.yml").read).result
    end
    assert_match(/must use different databases/, error.message)
  ensure
    ENV["DEVELOPMENT_DATABASE_NAME"] = previous_development
    ENV["TEST_DATABASE_NAME"] = previous_test
  end

  test "test boot rejects DATABASE_URL targeting the development database before application code runs" do
    environment = {
      "RAILS_ENV" => "test",
      "DATABASE_URL" => "postgresql://nudge:local@unreachable.invalid/nudge_development",
      "PROVIDER_MODE" => "fixture",
      "CJ_MODE" => "fixture"
    }
    stdout, stderr, status = Open3.capture3(
      environment,
      Rails.root.join("bin/rails").to_s,
      "runner",
      "puts 'DATABASE_QUERY_REACHED'; ActiveRecord::Base.connection.select_value('SELECT 1')"
    )

    refute_predicate status, :success?
    refute_includes stdout, "DATABASE_QUERY_REACHED"
    assert_includes stderr, "Development and test must use different databases"
    refute_match(/could not translate host name|connection.*failed/i, stderr)
  end

  test "rails test rejects an unsafe DATABASE_URL before schema maintenance" do
    environment = {
      "RAILS_ENV" => "test",
      "DATABASE_URL" => "postgresql://nudge:local@unreachable.invalid/nudge_development",
      "PROVIDER_MODE" => "fixture",
      "CJ_MODE" => "fixture",
      "DATABASE_SAFETY_PROBE" => "1"
    }
    stdout, stderr, status = Open3.capture3(
      environment,
      Rails.root.join("bin/rails").to_s,
      "test",
      "test/lib/test_foundation_test.rb"
    )

    refute_predicate status, :success?
    refute_includes stderr, "TEST_SCHEMA_MAINTENANCE_REACHED"
    assert_includes stderr, "Development and test must use different databases"
    refute_match(/could not translate host name|connection.*failed|schema_migrations/i, stdout + stderr)
  end

  test "rails test rejects a non-test DATABASE_URL before schema maintenance" do
    environment = {
      "RAILS_ENV" => "test",
      "DATABASE_URL" => "postgresql://nudge:local@unreachable.invalid/nudge_staging",
      "PROVIDER_MODE" => "fixture",
      "CJ_MODE" => "fixture",
      "DATABASE_SAFETY_PROBE" => "1"
    }
    stdout, stderr, status = Open3.capture3(
      environment,
      Rails.root.join("bin/rails").to_s,
      "test",
      "test/lib/test_foundation_test.rb"
    )

    refute_predicate status, :success?
    refute_includes stderr, "TEST_SCHEMA_MAINTENANCE_REACHED"
    refute_includes stdout, "DATABASE_QUERY_REACHED"
    assert_includes stderr, "Test database name must end in _test"
    refute_match(/could not translate host name|connection.*failed|schema_migrations/i, stdout + stderr)
  end

  test "production boot preserves DATABASE_URL without connecting during isolation validation" do
    environment = {
      "RAILS_ENV" => "production",
      "DATABASE_URL" => "postgresql://nudge:local@unreachable.invalid/nudge_production",
      "SECRET_KEY_BASE_DUMMY" => "1"
    }
    script = <<~RUBY
      config = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: "primary")
      abort unless config.database == "nudge_production"
      puts config.database
    RUBY
    stdout, stderr, status = Open3.capture3(
      environment,
      Rails.root.join("bin/rails").to_s,
      "runner",
      script
    )

    assert_predicate status, :success?, stderr
    assert_includes stdout, "nudge_production"
    refute_match(/could not translate host name|connection.*failed/i, stderr)
  end
end
