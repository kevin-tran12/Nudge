# The hosted demonstration runs the staging environment, which permits the
# server-authorized voice bootstrap. That bootstrap mints AI grants without a
# real Turnstile challenge, so an internet-reachable deployment must not be
# anonymously usable. Credentials come from the runtime; when either is absent
# the gate stays disabled, which keeps local development and tests untouched.
Rails.application.config.x.demo_access_gate = ActiveSupport::OrderedOptions.new.tap do |gate|
  username = ENV["DEMO_ACCESS_USERNAME"].presence
  password = ENV["DEMO_ACCESS_PASSWORD"].presence

  gate.username = username
  gate.password = password
  gate.enabled = username.present? && password.present?
end.freeze
