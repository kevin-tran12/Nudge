require "test_helper"

class Agents::Tools::GetCurrentShoppingStateTest < ActiveSupport::TestCase
  include TestSupport::IdentityRecords

  setup { clear_identity_records }
  teardown { clear_identity_records }

  test "returns a minimized session-derived projection with no client-supplied identifier" do
    user = create_user
    session = create_shopping_session(user:)
    tool = Agents::Tools::GetCurrentShoppingState.new

    result = tool.call(shopping_session: session, arguments: {})

    assert_equal "active", result.fetch("status")
    assert result.fetch("authenticated")
    assert_equal session.expires_at.utc.iso8601, result.fetch("expires_at")
    assert_equal %w[authenticated expires_at status], result.keys.sort
  end

  test "reports unauthenticated for a guest session" do
    session = create_shopping_session
    tool = Agents::Tools::GetCurrentShoppingState.new

    refute tool.call(shopping_session: session, arguments: {}).fetch("authenticated")
  end

  test "takes no identifier argument at all" do
    session = create_shopping_session
    tool = Agents::Tools::GetCurrentShoppingState.new

    [ { "shopping_session_id" => session.public_id }, { "user_id" => "anything" } ].each do |arguments|
      assert_raises(Agents::Tools::Error) { tool.call(shopping_session: session, arguments: arguments) }
    end
  end

  test "requires a real shopping session, never a client-supplied one" do
    tool = Agents::Tools::GetCurrentShoppingState.new

    assert_raises(ArgumentError) { tool.call(shopping_session: "not-a-session", arguments: {}) }
  end
end
