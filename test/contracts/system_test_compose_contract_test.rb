require "test_helper"
require "yaml"

class SystemTestComposeContractTest < ActiveSupport::TestCase
  OVERRIDE_PATH = Rails.root.join("compose.system-test.yaml")
  WRITABLE_TARGETS = %w[
    /rails/log
    /rails/storage
    /rails/tmp
    /rails/app/assets/builds
  ].freeze

  test "browser topology removes published ports and isolates its database" do
    services = compose.fetch("services")

    assert_match(/^\s+ports: !reset \[\]$/, source)
    assert_empty services.fetch("db").fetch("ports")
    assert_includes volume_sources(services.fetch("db")), "system_test_postgres_data"

    %w[browser system_app system_tests].each do |service_name|
      refute services.fetch(service_name).key?("ports"), "#{service_name} must not publish ports"
    end
  end

  test "Rails browser services run locked down with a read-only source tree" do
    %w[system_app system_tests].each do |service_name|
      service = compose.fetch("services").fetch(service_name)

      assert_equal "1000:1000", service.fetch("user")
      assert_includes service.fetch("security_opt"), "no-new-privileges:true"

      source_mount = service.fetch("volumes").find { |mount| mount.fetch("target") == "/rails" }
      assert_equal "bind", source_mount.fetch("type")
      assert_equal true, source_mount.fetch("read_only")

      WRITABLE_TARGETS.each do |target|
        mount = service.fetch("volumes").find { |candidate| candidate.fetch("target") == target }
        assert_equal "volume", mount&.fetch("type"), "#{service_name} needs a volume at #{target}"
      end
    end
  end

  test "test runner has isolated coverage and screenshot storage and uses the lane entry point" do
    runner = compose.fetch("services").fetch("system_tests")

    assert_equal [ "bin/test-browser" ], runner.fetch("command")
    assert_equal "1", runner.fetch("environment").fetch("RUN_BROWSER_TESTS")

    assert_equal "/coverage", runner.fetch("environment").fetch("COVERAGE_ROOT")
    assert_equal "system_test_coverage", volume_source_for(runner, "/coverage")
    assert_equal "system_tests_tmp", volume_source_for(runner, "/rails/tmp")
  end

  test "artifact exporter writes as the invoking host user without elevated privileges" do
    exporter = compose.fetch("services").fetch("artifact_export")

    assert_equal "${HOST_UID:-1000}:${HOST_GID:-1000}", exporter.fetch("user")
    assert_includes exporter.fetch("security_opt"), "no-new-privileges:true"
    assert_equal true, exporter.fetch("volumes").find { |mount| mount.fetch("target") == "/source/coverage" }.fetch("read_only")
    assert_equal true, exporter.fetch("volumes").find { |mount| mount.fetch("target") == "/source/tmp" }.fetch("read_only")
    assert_equal "bind", exporter.fetch("volumes").find { |mount| mount.fetch("target") == "/export" }.fetch("type")
  end

  private

  def source
    @source ||= OVERRIDE_PATH.read
  end

  def compose
    @compose ||= YAML.safe_load(source.gsub("!reset", ""))
  end

  def volume_sources(service)
    service.fetch("volumes").filter_map do |mount|
      mount["source"] if mount.is_a?(Hash)
    end
  end

  def volume_source_for(service, target)
    service.fetch("volumes").find { |mount| mount.fetch("target") == target }&.fetch("source")
  end
end
