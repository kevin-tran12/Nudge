module Identity
  # Cart pages/mutations need a shopping session to scope a cart to even before
  # a shopper has opted into voice (which is the only existing session bootstrap
  # path -- see Agents::VoiceSessionAuthorizer's demo-mode bootstrap). This concern
  # reuses that same minimal bootstrap shape (an anonymous, signed-cookie-bound
  # ShoppingSession) without any of voice's disclosure/Turnstile/grant machinery,
  # which cart does not need. It never accepts a session identifier from the
  # request; identity is always either the already-resolved trusted cookie
  # session or a freshly created one written back to that same signed cookie.
  module EnsuresShoppingSession
    extend ActiveSupport::Concern

    include Identity::CurrentShoppingContext

    # Matches the accepted AUTH-001 guest session lifetime (see DECISIONS.md).
    GUEST_SESSION_LIFETIME = 2.hours

    private
      def current_or_bootstrapped_shopping_session
        current_shopping_session || bootstrap_shopping_session!
      end

      def bootstrap_shopping_session!
        now = Time.current
        session = ShoppingSession.create!(
          user: nil, status: "active", started_at: now,
          last_activity_at: now, expires_at: now + GUEST_SESSION_LIFETIME
        )
        identity_browser_session_cookie.write(shopping_session: session)
        @identity_current_context = Identity::CurrentContext.new.call(shopping_session: session)
        session
      rescue ActiveRecord::ActiveRecordError, Identity::Error
        nil
      end
  end
end
