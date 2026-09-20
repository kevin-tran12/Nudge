require "active_support/security_utils"

# HTTP Basic gate for the internet-reachable demonstration deployment.
#
# Digesting both sides before comparison keeps the comparison constant time and
# independent of credential length, which a bare secure_compare on raw input
# would leak. Container health probes are exempt because Cloud Run cannot send
# credentials and would otherwise mark a healthy revision as failed.
module DemoAccessGate
  extend ActiveSupport::Concern

  EXEMPT_PATHS = %w[/up /health/ready].freeze
  REALM = "Nudge demonstration"

  included do
    before_action :require_demo_access!
  end

  private

  def require_demo_access!
    gate = Rails.application.config.x.demo_access_gate
    return unless gate&.enabled
    return if EXEMPT_PATHS.include?(request.path)

    authenticate_or_request_with_http_basic(REALM) do |username, password|
      matches?(username, gate.username) & matches?(password, gate.password)
    end
  end

  def matches?(given, expected)
    return false unless given.is_a?(String) && expected.is_a?(String)

    ActiveSupport::SecurityUtils.fixed_length_secure_compare(
      ::Digest::SHA256.digest(given),
      ::Digest::SHA256.digest(expected)
    )
  end
end
