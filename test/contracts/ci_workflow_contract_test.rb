require "test_helper"
require "yaml"

class CiWorkflowContractTest < ActiveSupport::TestCase
  setup do
    workflow_path = Rails.root.join(".github/workflows/ci.yml")
    @workflow = YAML.safe_load_file(workflow_path, aliases: false)
    @workflow_source = workflow_path.read
  end

  test "defines cancellable objective quality gates" do
    assert_equal true, @workflow.dig("concurrency", "cancel-in-progress")

    expected_jobs = %w[tests browser quality production-security]
    assert_empty expected_jobs - @workflow.fetch("jobs").keys
  end

  test "locks test jobs to fixture provider mode" do
    assert_equal "fixture", @workflow.dig("env", "PROVIDER_MODE")
    assert_equal "fixture", @workflow.dig("env", "CJ_MODE")
    refute_match(/PROVIDER_MODE:\s*(?:live|verify|record)/, @workflow_source)
    refute_match(/CJ_MODE:\s*(?:live|verify|record)/, @workflow_source)
  end

  test "retains required scans and production checks" do
    required_commands = %w[
      bin/rubocop
      bin/bundler-audit
      bin/brakeman
      secret,misconfig
      --target runtime
      --pkg-types os
    ] + [ "ruby test/runtime/production_image_contract.rb" ]

    required_commands.each do |required_command|
      assert_includes @workflow_source, required_command
    end
  end

  test "runs the production image contract unconditionally after the image build" do
    steps = @workflow.dig("jobs", "production-security", "steps")
    build_index = steps.index { |step| step["name"] == "Build production image" }
    contract_index = steps.index { |step| step["name"] == "Verify production image contract" }

    assert_equal build_index + 1, contract_index
    assert_nil steps.fetch(contract_index)["if"]
  end

  test "runs coverage with read-only source and exports the named volume" do
    assert_includes @workflow_source, ":/rails:ro"
    assert_includes @workflow_source, "coverage.tar.gz"
    assert_includes @workflow_source, "tar -C /coverage"
    refute_includes @workflow_source, "coverage/\n"
  end

  test "publishes test evidence even when a lane fails" do
    assert_includes @workflow_source, "actions/upload-artifact@"
    assert_includes @workflow_source, "if: always()"
    assert_includes @workflow_source, "coverage.tar.gz"
    assert_includes @workflow_source, "tmp/test-results/"
  end

  test "runs the browser lane in an isolated Compose project" do
    job = @workflow.fetch("jobs").fetch("browser")
    steps = job.fetch("steps")
    source = steps.filter_map { |step| step["run"] }.join("\n")

    assert_nil job["if"]
    assert_includes source, '-p "$BROWSER_COMPOSE_PROJECT"'
    assert_includes source, "-f compose.yaml -f compose.system-test.yaml"
    assert_includes source, "exec -T system_app ruby test/runtime/system_test_container_contract.rb"
    assert_includes source, "run --rm --no-deps system_tests ruby test/runtime/system_test_container_contract.rb"
    assert_includes source, "run --rm --no-deps system_tests bin/test-browser"
    assert_includes source, "set -o pipefail"
    refute_includes source, "continue-on-error"
  end

  test "exports and uploads browser evidence before teardown even after failure" do
    steps = @workflow.dig("jobs", "browser", "steps")
    app_contract_index = step_index(steps, "Verify browser application container contract")
    runner_contract_index = step_index(steps, "Verify browser runner container contract")
    browser_index = step_index(steps, "Run browser system tests")
    export_index = step_index(steps, "Export browser evidence")
    upload_index = step_index(steps, "Upload browser evidence")
    teardown_index = step_index(steps, "Tear down browser services")

    assert_operator app_contract_index, :<, runner_contract_index
    assert_operator runner_contract_index, :<, browser_index
    assert_operator browser_index, :<, export_index
    assert_operator export_index, :<, upload_index
    assert_operator upload_index, :<, teardown_index
    assert_equal "always()", steps.fetch(export_index).fetch("if")
    assert_equal "always()", steps.fetch(upload_index).fetch("if")
    assert_equal "always()", steps.fetch(teardown_index).fetch("if")
    assert_includes steps.fetch(export_index).fetch("run"), "artifact_export"
    assert_equal "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", steps.fetch(upload_index).fetch("uses")
    assert_includes steps.fetch(upload_index).dig("with", "path"), "tmp/browser-artifacts/"
    assert_includes steps.fetch(upload_index).dig("with", "path"), "tmp/browser-results/"
  end

  private

  def step_index(steps, name)
    steps.index { |step| step["name"] == name } || flunk("Missing #{name.inspect} step")
  end
end
