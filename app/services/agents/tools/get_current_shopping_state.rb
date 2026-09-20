module Agents
  module Tools
    # Takes no identifier argument at all. The session is resolved server-side by the
    # controller from the trusted cookie/grant context before this tool ever runs.
    class GetCurrentShoppingState
      def call(shopping_session:, arguments:)
        raise ArgumentError, "invalid shopping_session" unless shopping_session.is_a?(ShoppingSession)
        raise Error.new(:invalid_arguments) unless arguments.is_a?(Hash) && arguments.empty?

        {
          "status" => shopping_session.status,
          "expires_at" => shopping_session.expires_at.utc.iso8601,
          "authenticated" => shopping_session.user_id.present?
        }
      end
    end
  end
end
