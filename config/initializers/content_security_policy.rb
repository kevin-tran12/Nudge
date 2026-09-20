# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data
    policy.object_src  :none
    policy.base_uri    :none
    policy.frame_ancestors :none
    policy.form_action :self
    policy.style_src   :self
    policy.script_src  :self,
      "https://unpkg.com" # ELEVENLABS-SPECIFIC: removable — serves the ElevenLabs Convai widget embed script.
    policy.connect_src :self,
      "https://api.elevenlabs.io", # ELEVENLABS-SPECIFIC: removable — ElevenLabs REST calls made from the browser widget.
      "wss://api.elevenlabs.io"    # ELEVENLABS-SPECIFIC: removable — ElevenLabs realtime conversation transport.
  end

  # Generate a fresh per-request nonce for scripts (including importmap/inline
  # script tags) rather than reusing the session id.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Automatically add `nonce` to `javascript_tag`/`javascript_include_tag` when the
  # corresponding directive is nonce-protected above.
  config.content_security_policy_nonce_auto = true

  # Enforce, not just report.
  config.content_security_policy_report_only = false
end
