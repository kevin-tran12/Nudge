require "test_helper"

class DemoAccessGateTest < ActionDispatch::IntegrationTest
  USERNAME = "demo-visitor".freeze
  PASSWORD = "demo-visitor-password".freeze

  setup { @previous_gate = Rails.application.config.x.demo_access_gate }
  teardown { Rails.application.config.x.demo_access_gate = @previous_gate }

  test "the gate is inert when credentials are not configured" do
    configure_gate(username: nil, password: nil, enabled: false)

    get "/"

    assert_response :success
  end

  test "an enabled gate refuses anonymous access and advertises basic auth" do
    configure_gate

    get "/"

    assert_response :unauthorized
    assert_match(/\ABasic realm=/, response.headers["WWW-Authenticate"].to_s)
  end

  test "an enabled gate refuses wrong credentials on every protected path" do
    configure_gate

    [ "/", "/products" ].each do |path|
      get path, headers: { "HTTP_AUTHORIZATION" => basic(USERNAME, "wrong-password") }
      assert_response :unauthorized, "#{path} accepted a wrong password"

      get path, headers: { "HTTP_AUTHORIZATION" => basic("wrong-user", PASSWORD) }
      assert_response :unauthorized, "#{path} accepted a wrong username"
    end
  end

  test "an enabled gate admits correct credentials" do
    configure_gate

    get "/", headers: { "HTTP_AUTHORIZATION" => basic(USERNAME, PASSWORD) }

    assert_response :success
  end

  test "container health probes stay reachable without credentials" do
    configure_gate

    get "/up"
    assert_response :success

    get "/health/ready"
    assert_response :success
  end

  test "the voice session endpoint is not reachable without credentials" do
    configure_gate

    post "/voice/session", headers: { "Origin" => "http://www.example.com" }

    assert_response :unauthorized
  end

  private

  def configure_gate(username: USERNAME, password: PASSWORD, enabled: true)
    Rails.application.config.x.demo_access_gate = ActiveSupport::OrderedOptions.new.tap do |gate|
      gate.username = username
      gate.password = password
      gate.enabled = enabled
    end
  end

  def basic(username, password)
    ActionController::HttpAuthentication::Basic.encode_credentials(username, password)
  end
end
