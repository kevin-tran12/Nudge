require "test_helper"

class LocalCiContractTest < ActiveSupport::TestCase
  test "local CI does not invoke missing repository commands" do
    ci_source = Rails.root.join("config/ci.rb").read
    invoked_bins = ci_source.scan(%r{"(bin/[a-z0-9_-]+)}).flatten.uniq
    missing_bins = invoked_bins.reject { |command| Rails.root.join(command).file? }

    assert_empty missing_bins, "Missing CI commands: #{missing_bins.join(", ")}"
  end
end
