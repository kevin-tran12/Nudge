require "test_helper"

class TestFoundationTest < ActiveSupport::TestCase
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
