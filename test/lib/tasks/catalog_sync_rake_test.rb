require "test_helper"
require "rake"

# CAT-SYNC-01: the Cloud Run entry point. Fixture is the default; record mode
# needs both an explicit selector and a present credential, and a
# misconfiguration fails closed instead of silently calling CJ.
class CatalogSyncRakeTest < ActiveSupport::TestCase
  ENV_KEYS = %w[
    CATALOG_SYNC_MODE CATALOG_SYNC_PRODUCT_LIMIT CATALOG_SYNC_PAGE_SIZE CATALOG_SYNC_CATEGORY
    CATALOG_SYNC_KEYWORD CATALOG_SYNC_MAX_VARIANTS CATALOG_SYNC_DRY_RUN
  ].freeze

  setup do
    Rails.application.load_tasks if Rake::Task.task_defined?("catalog:sync") == false
    Rake::Task["catalog:sync"].reenable
  end

  test "defaults to fixture mode, imports nothing, and makes no supplier call" do
    output, = with_env({}) { capture_io { Rake::Task["catalog:sync"].invoke } }

    assert_match(/mode=fixture/, output)
    assert_match(/products_imported=0/, output)
    assert_match(/no supplier call/i, output)
    assert_equal 0, SupplierProduct.count
  end

  test "an unrecognized mode fails closed instead of degrading to record" do
    _out, err = with_env({ "CATALOG_SYNC_MODE" => "live" }) do
      capture_io { assert_raises(SystemExit) { Rake::Task["catalog:sync"].invoke } }
    end

    assert_match(/CATALOG_SYNC_MODE/, err)
    assert_equal 0, SupplierProduct.count
  end

  test "record mode is refused when the CJ credential is absent" do
    _out, err = with_env({ "CATALOG_SYNC_MODE" => "record" }, credential: nil) do
      capture_io { assert_raises(SystemExit) { Rake::Task["catalog:sync"].invoke } }
    end

    assert_match(/credential/i, err)
    assert_equal 0, SupplierProduct.count
  end

  test "record mode still fails closed in a deployment that does not allow it" do
    # db:prepare seeds this row on a fresh database, so the test must tolerate
    # it already existing rather than assume it creates it.
    Supplier.find_or_create_by!(key: "cj") do |supplier|
      supplier.display_name = "CJ Dropshipping"
      supplier.adapter_version = "1"
      supplier.api_version = "v1"
      supplier.status = "active"
    end
    error = nil
    with_env({ "CATALOG_SYNC_MODE" => "record", "CATALOG_SYNC_CATEGORY" => "home" },
      credential: "synthetic-not-a-real-key") do
      capture_io { error = assert_raises(Integrations::Cj::Error) { Rake::Task["catalog:sync"].invoke } }
    end

    assert_equal :unsupported_mode, error.code
    assert_equal 0, SupplierProduct.count
  end

  test "record mode requires at least one filter" do
    _out, err = with_env({ "CATALOG_SYNC_MODE" => "record", "CATALOG_SYNC_CATEGORY" => "",
      "CATALOG_SYNC_KEYWORD" => "" }, credential: "synthetic-not-a-real-key") do
      capture_io { assert_raises(SystemExit) { Rake::Task["catalog:sync"].invoke } }
    end

    assert_match(/CATALOG_SYNC_CATEGORY/, err)
  end

  test "an out-of-range product limit fails closed" do
    _out, err = with_env({ "CATALOG_SYNC_PRODUCT_LIMIT" => "0" }) do
      capture_io { assert_raises(SystemExit) { Rake::Task["catalog:sync"].invoke } }
    end

    assert_match(/CATALOG_SYNC_PRODUCT_LIMIT/, err)
  end

  test "the printed summary never contains the credential" do
    secret = "cj-secret-value-do-not-print"
    output, = with_env({}, credential: secret) { capture_io { Rake::Task["catalog:sync"].invoke } }

    refute_includes output, secret
  end

  private
    def with_env(overrides, credential: :unset)
      previous = ENV_KEYS.to_h { |key| [ key, ENV[key] ] }
      previous_config = Rails.application.config.x.cj
      ENV_KEYS.each { |key| ENV.delete(key) }
      overrides.each { |key, value| ENV[key] = value }
      unless credential == :unset
        Rails.application.config.x.cj = Integrations::Cj::Config.new(api_key: credential).freeze
      end
      yield
    ensure
      previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      Rails.application.config.x.cj = previous_config
    end
end
