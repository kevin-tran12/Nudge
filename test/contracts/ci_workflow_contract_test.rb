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

    expected_jobs = %w[tests quality production-security]
    assert_empty expected_jobs - @workflow.fetch("jobs").keys
  end

  test "locks test jobs to fixture provider mode" do
    assert_equal "fixture", @workflow.dig("env", "PROVIDER_MODE")
    refute_match(/PROVIDER_MODE:\s*(?:live|verify|record)/, @workflow_source)
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

  test "does not claim browser coverage before the browser lane exists" do
    refute_match(/bin\/test-browser/, @workflow_source)
  end
end
