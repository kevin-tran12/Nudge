require "test_helper"
require "rake"
require "fileutils"
require "tmpdir"

# prodigi:capture is the operator-run, credential-gated step that happens
# AFTER this PR merges, once a human supplies a real Prodigi sandbox key. In
# this phase and in CI (test deployment) it must always refuse before ever
# reaching the network: ModePolicy forces fixture-only in the test
# deployment regardless of what SKUS/credentials are supplied, so this task
# can never accidentally spend a real capture call in the test suite.
class ProdigiCaptureRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.task_defined?("prodigi:capture") == false
    Rake::Task["prodigi:capture"].reenable
  end

  test "SKUS is required" do
    _out, err = with_env({}) { capture_io { assert_raises(SystemExit) { Rake::Task["prodigi:capture"].invoke } } }
    assert_match(/SKUS/, err)
  end

  test "an empty SKUS value is refused the same as a missing one" do
    _out, err = with_env({ "SKUS" => "  " }) { capture_io { assert_raises(SystemExit) { Rake::Task["prodigi:capture"].invoke } } }
    assert_match(/SKUS/, err)
  end

  test "more than 60 SKUs is refused" do
    skus = (1..61).map { |i| "SKU-#{i}" }.join(",")
    _out, err = with_env({ "SKUS" => skus }) { capture_io { assert_raises(SystemExit) { Rake::Task["prodigi:capture"].invoke } } }
    assert_match(/60/, err)
  end

  test "exactly 60 SKUs passes the count check (though it still refuses for lack of sandbox credentials)" do
    skus = (1..60).map { |i| "SKU-#{i}" }.join(",")
    _out, err = with_env({ "SKUS" => skus }, credential: nil) do
      capture_io { assert_raises(SystemExit) { Rake::Task["prodigi:capture"].invoke } }
    end
    assert_match(/sandbox|credential/i, err)
  end

  test "without a credential the task refuses clearly rather than attempting an unauthenticated call" do
    _out, err = with_env({ "SKUS" => "GLOBAL-CFPM-16X24" }, credential: nil) do
      capture_io { assert_raises(SystemExit) { Rake::Task["prodigi:capture"].invoke } }
    end
    assert_match(/sandbox/i, err)
    assert_match(/credential/i, err)
  end

  test "configured in fixture mode (not sandbox) the task also refuses" do
    _out, err = with_env({ "SKUS" => "GLOBAL-CFPM-16X24" }, credential: "synthetic-not-a-real-key", mode: "fixture") do
      capture_io { assert_raises(SystemExit) { Rake::Task["prodigi:capture"].invoke } }
    end
    assert_match(/sandbox/i, err)
  end

  test "sandbox mode with a credential still fails closed in the test deployment instead of silently proceeding" do
    error = nil
    with_env({ "SKUS" => "GLOBAL-CFPM-16X24" }, credential: "synthetic-not-a-real-key", mode: "sandbox") do
      capture_io { error = assert_raises(Integrations::Prodigi::Error) { Rake::Task["prodigi:capture"].invoke } }
    end
    assert_equal :unsupported_mode, error.code
  end

  test "the printed refusal never contains the configured credential" do
    secret = "prodigi-secret-value-do-not-print"
    _out, err = with_env({ "SKUS" => "GLOBAL-CFPM-16X24" }, credential: secret, mode: "fixture") do
      capture_io { assert_raises(SystemExit) { Rake::Task["prodigi:capture"].invoke } }
    end
    refute_includes err, secret
  end

  test "write_capture writes the raw body to <root>/<operation>/<id>.json without touching the network" do
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      ProdigiCapture.write_capture(root, :product, "GLOBAL-CFPM-16X24", '{"outcome":"Ok"}')

      written = root.join("product", "GLOBAL-CFPM-16X24.json")
      assert written.exist?
      assert_equal '{"outcome":"Ok"}', written.read
    end
  end

  test "write_capture creates the operation subdirectory on demand and does not clobber other operations" do
    Dir.mktmpdir do |dir|
      root = Pathname.new(dir)
      refute root.join("order_status").exist?

      ProdigiCapture.write_capture(root, :order_status, "ord_1", "{}")
      ProdigiCapture.write_capture(root, :product, "SKU-1", "{}")

      assert root.join("order_status").directory?
      assert root.join("product").directory?
      assert root.join("order_status", "ord_1.json").exist?
      assert root.join("product", "SKU-1.json").exist?
    end
  end

  private
    def with_env(overrides, credential: :unset, mode: "sandbox")
      previous_skus = ENV["SKUS"]
      previous_config = Rails.application.config.x.prodigi
      ENV.delete("SKUS")
      overrides.each { |key, value| ENV[key] = value }
      unless credential == :unset
        Rails.application.config.x.prodigi = Integrations::Prodigi::Config.new(api_key: credential, mode: mode).freeze
      end
      yield
    ensure
      previous_skus.nil? ? ENV.delete("SKUS") : ENV["SKUS"] = previous_skus
      Rails.application.config.x.prodigi = previous_config
    end
end
