require "test_helper"
require "yaml"

class ComposeTestContractTest < ActiveSupport::TestCase
  test "coverage uses a writable named volume outside the source bind" do
    compose_source = Rails.root.join("compose.yaml").read
    compose = YAML.safe_load(compose_source, aliases: true)
    app = compose.dig("services", "app")

    assert_equal "/coverage", app.dig("environment", "COVERAGE_ROOT")
    assert_includes app.fetch("volumes"), "rails_coverage:/coverage"
    assert compose.fetch("volumes").key?("rails_coverage")
    assert_includes Rails.root.join("Dockerfile").read, "/coverage"
    assert_equal "1000:1000", app.fetch("user")
    assert_includes app.fetch("security_opt"), "no-new-privileges:true"
  end
end
