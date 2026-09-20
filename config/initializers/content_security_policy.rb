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
    # ELEVENLABS-SPECIFIC: removable — the conversation token is a LiveKit room
    # token, so the widget negotiates realtime audio against LiveKit rather than
    # against api.elevenlabs.io alone. Audio worklets and captured media are
    # delivered as blob URLs.
    policy.connect_src :self,
      "https://api.elevenlabs.io",
      "wss://api.elevenlabs.io",
      "https://*.livekit.cloud",
      "wss://*.livekit.cloud",
      :blob
    policy.worker_src  :self, :blob # ELEVENLABS-SPECIFIC: removable — audio worklet workers.
    policy.media_src   :self, :blob # ELEVENLABS-SPECIFIC: removable — realtime audio playback.
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
