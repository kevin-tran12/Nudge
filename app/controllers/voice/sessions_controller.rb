module Voice
  # POST /voice/session — issues a short-lived ElevenLabs conversation
  # authorization for the caller's server-resolved shopping session. Identity is
  # resolved entirely server-side (Identity::CurrentShoppingContext, via the signed
  # session cookie); no parameter, header, or body field may select a session or
  # user. See Agents::VoiceSessionAuthorizer for the demo-mode bootstrap this
  # delegates to.
  class SessionsController < ApplicationController
    STATUS_BY_CODE = {
      invalid_input: :bad_request,
      demo_mode_unavailable: :forbidden,
      session_bootstrap_failed: :service_unavailable,
      consent_required: :forbidden,
      verification_failed: :forbidden,
      grant_conflict: :conflict,
      session_limit_reached: :too_many_requests,
      provider_unavailable: :service_unavailable
    }.freeze

    def create
      result = Agents::VoiceSessionAuthorizer.new.call(
        cookie: identity_browser_session_cookie,
        context: identity_current_context,
        expected_hostname: request.host
      )
      render json: result, status: :created
    rescue Agents::VoiceSessionAuthorizer::Error => error
      render json: { error: error.code.to_s }, status: STATUS_BY_CODE.fetch(error.code, :unprocessable_entity)
    end
  end
end
