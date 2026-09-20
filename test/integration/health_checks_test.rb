require "test_helper"

class HealthChecksTest < ActionDispatch::IntegrationTest
  test "liveness confirms the Rails process is running" do
    get "/up"

    assert_response :success
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  test "readiness confirms the database is reachable" do
    get "/health/ready"

    assert_response :success
    assert_equal({ "status" => "ok" }, response.parsed_body)
  end

  test "readiness fails closed without exposing database details" do
    pool = ActiveRecord::Base.connection_pool
    original = pool.method(:with_connection)
    pool.define_singleton_method(:with_connection) do |*_args, **_kwargs, &_block|
      raise ActiveRecord::ConnectionNotEstablished
    end

    get "/health/ready"

    assert_response :service_unavailable
    assert_equal(
      { "status" => "unavailable" },
      response.parsed_body
    )
  ensure
    pool&.define_singleton_method(:with_connection, original) if original
  end
end
