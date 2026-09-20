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
    # ELEVENLABS-SPECIFIC: removable — the widget renders into a shadow root and
    # injects its own <style> elements, which cannot carry our nonce. Inline
    # styles cannot execute script, so this is materially weaker than allowing
    # inline script and is scoped to styles only.
    policy.style_src   :self, :unsafe_inline
    policy.script_src  :self,
      "https://unpkg.com", # ELEVENLABS-SPECIFIC: removable — serves the ElevenLabs Convai widget embed script.
      # ELEVENLABS-SPECIFIC: removable — hash of the one inline bootstrap script the
      # widget injects. A hash keeps this pinned to exact known content rather than
      # allowing arbitrary inline script, and will fail closed if the widget changes.
      "'sha256-u4LormfPAY/QEubWr2N+8pA8yLzlKw7dYv1+nFC3DX4='",
      "'sha256-RO6OQPIs99YhryaC9EX8uMR9dAnpBOPtZXLRqf32K8Q='"
    # ELEVENLABS-SPECIFIC: removable — the conversation token is a LiveKit room
    # token, so the widget negotiates realtime audio against LiveKit rather than
    # against api.elevenlabs.io alone. Audio worklets and captured media are
    # delivered as blob URLs.
    policy.connect_src :self,
      "https://*.elevenlabs.io",  # covers regional hosts such as api.us.elevenlabs.io
      "wss://*.elevenlabs.io",
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

  # The ElevenLabs widget injects inline scripts whose content varies per load, so
  # no fixed hash set can cover them and a nonce cannot reach a script the widget
  # writes itself. Enforce the policy in production, where the widget is not part
  # of the supported path, and report without blocking elsewhere so a demonstration
  # is not broken by a third-party embed. This is deliberately not "allow inline
  # script everywhere": production keeps the strict policy, and violations are still
  # reported in other environments.
  config.content_security_policy_report_only = !Rails.env.production?
end
