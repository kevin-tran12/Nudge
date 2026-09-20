require "test_helper"

class CurrentShoppingContextProbeController < ApplicationController
  def show
    render json: {
      "session_public_id" => current_shopping_session&.public_id,
      "user_public_id" => current_user&.public_id
    }
  end
end

class CurrentShoppingContextTest < ActionController::TestCase
  include TestSupport::IdentityRecords

  tests CurrentShoppingContextProbeController

  setup do
    clear_identity_records
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { get "show" => "current_shopping_context_probe#show" }
  end

  teardown { clear_identity_records }

  test "controller derives session and user only from the signed cookie" do
    user = create_user
    session = create_shopping_session(user:)
    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = signed_cookie_for(session)

    get :show, params: { shopping_session_id: create_shopping_session.public_id, user_id: create_user.public_id }

    assert_response :success
    payload = response.parsed_body
    assert_equal session.public_id, payload.fetch("session_public_id")
    assert_equal user.public_id, payload.fetch("user_public_id")
  end

  test "absent and invalid cookies remain anonymous without creating state" do
    assert_no_difference -> { ShoppingSession.count } do
      get :show
      assert_response :success
      assert_nil response.parsed_body.fetch("session_public_id")

      cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = "invalid-cookie"
      get :show
      assert_response :success
      assert_nil response.parsed_body.fetch("session_public_id")
    end
  end

  test "parameters headers and request bodies cannot select identity" do
    selected = create_shopping_session(user: create_user)
    @request.headers["X-Shopping-Session"] = selected.public_id
    @request.headers["Authorization"] = "Session #{selected.public_id}"

    get :show, params: {
      shopping_session_id: selected.public_id,
      user_id: selected.user.public_id,
      current_shopping_session: { public_id: selected.public_id }
    }

    assert_response :success
    assert_nil response.parsed_body.fetch("session_public_id")
    assert_nil response.parsed_body.fetch("user_public_id")
  end

  test "cookie and identity parameters are filtered from logs" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      "nudge_shopping_session" => "sentinel-cookie",
      "shopping_session_cookie" => "sentinel-alias"
    )

    assert_equal "[FILTERED]", filtered.fetch("nudge_shopping_session")
    assert_equal "[FILTERED]", filtered.fetch("shopping_session_cookie")
  end


  private

  def signed_cookie_for(session)
    request = ActionDispatch::TestRequest.create
    jar = ActionDispatch::Cookies::CookieJar.build(request, {})
    Identity::BrowserSessionCookie.new(
      cookie_jar: jar,
      clock: -> { TestSupport::IdentityRecords::REFERENCE_TIME },
      secure: false,
      environment: "test"
    ).write(shopping_session: session)
    jar[Identity::BrowserSessionCookie::COOKIE_NAME]
  end
end

class CurrentShoppingContextPublicPagesTest < ActionDispatch::IntegrationTest
  test "home and catalog remain usable without identity and with a malformed cookie" do
    get "/"
    assert_response :success

    cookies[Identity::BrowserSessionCookie::COOKIE_NAME] = "malformed"
    get "/products"
    assert_response :success
  end
end
