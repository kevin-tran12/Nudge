require "test_helper"

class CjConfigTest < ActiveSupport::TestCase
  test "credentials_present reflects a real api_key and never leaks it" do
    present = Integrations::Cj::Config.new(api_key: "synthetic-secret-key")
    absent = Integrations::Cj::Config.new(api_key: nil)

    assert present.credentials_present?
    refute absent.credentials_present?
    refute_includes present.inspect, "synthetic-secret-key"
    refute_includes present.to_s, "synthetic-secret-key"
    refute_includes present.as_json.inspect, "synthetic-secret-key"
    refute_includes present.to_json, "synthetic-secret-key"
  end

  test "the application-wide config is frozen and boots without a credential" do
    config = Rails.application.config.x.cj
    assert_instance_of Integrations::Cj::Config, config
    assert config.frozen?
  end
end
