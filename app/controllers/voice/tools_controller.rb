module Voice
  # Executes narrow, strictly-schema'd application tools on behalf of the ElevenLabs
  # conversational agent.
  #
  # Trust model: this endpoint is called as an ElevenLabs *client tool*, i.e. a
  # same-origin fetch from our own page's JavaScript, not a server-side webhook. No
  # cloud infrastructure exists yet (WP-04 unstarted), the app runs on localhost, and
  # ElevenLabs' servers cannot reach localhost -- so a server-side tool webhook keyed on
  # ELEVENLABS_TOOL_SECRET could never be invoked for this demo. Identity is therefore
  # resolved the same way every other authenticated page request resolves it: the signed
  # `nudge_shopping_session` cookie via Identity::CurrentShoppingContext, with standard
  # Rails CSRF protection enforced (never skipped here) and an explicit same-origin check
  # on top of it. A valid session cookie alone is not enough to reach voice tools -- the
  # caller must additionally hold an active Identity::AiGrantAuthorizer-verified AI grant
  # scoped to that same session.
  #
  # ELEVENLABS_TOOL_SECRET is read by name only, from ENV/config, and is intentionally
  # unused by this controller for now: retaining a shared-secret server-webhook path here
  # would require a publicly reachable origin (real deployment, WP-04) and would meaningfully
  # complicate this controller's trust model for no benefit in a localhost demo. If/when a
  # deployed server-tool configuration exists, add that path as a separate, explicit
  # authentication branch rather than folding it into the cookie/grant path above.
  #
  # Note: request bodies here are parsed by hand from `request.raw_post` (never via
  # `params`/`request.request_parameters`). The vendored `json` gem in this app's current
  # lockfile is incompatible with Rails' own `ActiveSupport::JSON.decode` (it calls
  # `JSON.parse(json, options)` positionally, which the installed json 3.0.2 no longer
  # accepts), so touching `params` on any JSON POST raises ArgumentError app-wide. That is
  # a pre-existing dependency defect outside this work package's scope -- flagged
  # separately -- not something introduced here; this controller simply avoids the broken
  # path.
  class ToolsController < ApplicationController
    MAX_BODY_BYTES = 8_192

    TOOLS = {
      "search_products" => Agents::Tools::SearchProducts,
      "get_product_details" => Agents::Tools::GetProductDetails,
      "recommend_products" => Agents::Tools::RecommendProducts,
      "update_requirements" => Agents::Tools::UpdateRequirements,
      "get_current_shopping_state" => Agents::Tools::GetCurrentShoppingState
    }.freeze

    rescue_from ActionController::InvalidAuthenticityToken, with: :render_invalid_csrf

    before_action :enforce_body_limit!
    before_action :enforce_same_origin!
    before_action :require_shopping_session!
    before_action :require_active_grant!
    before_action :require_known_tool!

    def call
      result = @tool_class.new.call(shopping_session: @shopping_session, arguments: tool_arguments)
      render json: result, status: :ok
    rescue Agents::Tools::Error => error
      render_tool_error(error)
    end

    private
      def enforce_body_limit!
        length = request.content_length
        render_error(:payload_too_large, :payload_too_large) if length && length > MAX_BODY_BYTES
      end

      def enforce_same_origin!
        return if performed?

        origin = request.headers["Origin"]
        render_error(:cross_origin_rejected, :forbidden) unless origin.present? && origin == request.base_url
      end

      def require_shopping_session!
        return if performed?

        @shopping_session = current_shopping_session
        render_error(:session_required, :unauthorized) unless @shopping_session
      end

      def require_active_grant!
        return if performed?

        token = bearer_token
        return render_error(:grant_required, :unauthorized) unless token

        @grant = Identity::AiGrantAuthorizer.new.call(
          shopping_session: @shopping_session, bearer_token: token
        ).grant
      rescue Identity::Error
        render_error(:grant_required, :unauthorized)
      end

      def require_known_tool!
        return if performed?

        @tool_class = TOOLS[request.path_parameters[:tool_name]]
        render_error(:unknown_tool, :not_found) unless @tool_class
      end

      def bearer_token
        header = request.headers["Authorization"]
        return unless header.is_a?(String)

        match = header.match(/\ABearer (.+)\z/)
        match && match[1]
      end

      def tool_arguments
        body = request.raw_post
        return {} if body.nil? || body.empty?

        parsed = JSON.parse(body)
        raise JSON::ParserError unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError, EncodingError
        raise Agents::Tools::Error.new(:invalid_arguments)
      end

      def render_invalid_csrf
        render_error(:invalid_csrf_token, :unprocessable_entity)
      end

      def render_error(code, status)
        render json: { "error" => { "code" => code.to_s } }, status: status
      end

      def render_tool_error(error)
        status = case error.code
        when :not_found then :not_found
        when :invalid_arguments then :unprocessable_entity
        else :service_unavailable
        end
        render json: { "error" => { "code" => error.code.to_s } }, status: status
      end
  end
end
