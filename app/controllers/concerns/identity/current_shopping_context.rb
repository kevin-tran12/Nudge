module Identity
  module CurrentShoppingContext
    extend ActiveSupport::Concern

    included do
      helper_method :current_shopping_session, :current_user
    end

    private

    def current_shopping_session
      identity_current_context&.current_shopping_session
    end

    def current_user
      identity_current_context&.current_user
    end

    def identity_current_context
      return @identity_current_context if defined?(@identity_current_context)

      @identity_current_context = identity_browser_session_cookie.resolve
    end

    def identity_browser_session_cookie
      @identity_browser_session_cookie ||= Identity::BrowserSessionCookie.new(cookie_jar: cookies)
    end
  end
end
