require "test_helper"
require "erb"

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
end
