require "test_helper"

class ProdigiConfigTest < ActiveSupport::TestCase
  test "sandbox? is true only when mode is the literal sandbox string and api_key is present" do
    both = Integrations::Prodigi::Config.new(api_key: "synthetic-secret-key", mode: "sandbox")
    assert both.sandbox?

    no_key = Integrations::Prodigi::Config.new(api_key: nil, mode: "sandbox")
    refute no_key.sandbox?

    no_mode = Integrations::Prodigi::Config.new(api_key: "synthetic-secret-key", mode: "fixture")
    refute no_mode.sandbox?

    neither = Integrations::Prodigi::Config.new(api_key: nil, mode: "fixture")
    refute neither.sandbox?
  end

  test "an unrecognized mode string is never treated as sandbox, even with credentials present" do
    [ "sandbox; drop table", "SANDBOX", "live", "true", "1", "", nil ].each do |mode|
      config = Integrations::Prodigi::Config.new(api_key: "synthetic-secret-key", mode: mode)
      refute config.sandbox?, "mode #{mode.inspect} must not select sandbox"
    end
  end

  test "an empty-string api_key does not count as present" do
    config = Integrations::Prodigi::Config.new(api_key: "", mode: "sandbox")
    refute config.credentials_present?
    refute config.sandbox?
  end

  test "credentials_present? reflects only whether api_key is present" do
    assert Integrations::Prodigi::Config.new(api_key: "synthetic-secret-key", mode: "fixture").credentials_present?
    refute Integrations::Prodigi::Config.new(api_key: nil, mode: "fixture").credentials_present?
  end

  test "the api_key never leaks through inspect, to_s, as_json, or to_json" do
    secret = "synthetic-prodigi-secret-key"
    config = Integrations::Prodigi::Config.new(api_key: secret, mode: "sandbox")

    refute_includes config.inspect, secret
    refute_includes config.to_s, secret
    refute_includes config.as_json.to_s, secret
    refute_includes config.to_json, secret
  end

  test "the application-wide config is frozen and boots without a credential" do
    config = Rails.application.config.x.prodigi
    assert_instance_of Integrations::Prodigi::Config, config
    assert config.frozen?
    refute config.sandbox?
  end
end
