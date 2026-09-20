require "test_helper"

class TestFoundationTest < ActiveSupport::TestCase
  test "SimpleCov is available in the development test image" do
    assert Gem.loaded_specs.key?("simplecov")
  end

  test "coverage output is outside the source checkout" do
    coverage_root = Pathname(ENV.fetch("COVERAGE_ROOT") { File.join(Dir.tmpdir, "nudge-coverage") })

    assert_equal coverage_root.join(ENV.fetch("TEST_LANE", "all")).to_s, SimpleCov.coverage_path
    refute SimpleCov.coverage_path.to_s.start_with?(Rails.root.to_s)
  end

  test "test helper does not defer database safety until after rails test help" do
    source = Rails.root.join("test/test_helper.rb").read
    rails_test_help = source.index('require "rails/test_help"')
    late_source = source[rails_test_help..]

    refute_includes late_source, "connection_db_config"
  end

  test "the test process is locked to fixture provider mode" do
    assert_equal "fixture", ENV.fetch("PROVIDER_MODE")
  end

  test "unique test values are namespaced and do not collide" do
    first = unique_test_value("shopping-session")
    second = unique_test_value("shopping-session")

    assert_match(/\Ashopping-session-[a-z0-9-]+\z/, first)
    refute_equal first, second
  end

  test "the test database is isolated by name" do
    assert_match(/(?:^|_)test\z/, ActiveRecord::Base.connection_db_config.database)
  end

  test "fast and integration selectors are disjoint" do
    fast = TestSupport::TestLane.files(:fast)
    integration = TestSupport::TestLane.files(:integration)

    assert_includes fast, Rails.root.join("test/lib/test_foundation_test.rb").to_s
    assert_includes integration, Rails.root.join("test/integration/health_checks_test.rb").to_s
    assert_empty fast & integration
  end
end
