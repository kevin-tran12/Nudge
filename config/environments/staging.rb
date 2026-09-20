require "active_support/core_ext/integer/time"

# Staging is the production-shaped demonstration deployment. It matches production
# behavior except that it permits the server-authorized demo bootstrap, which
# provisions the guest session, disclosure consent, and verification evidence that
# the voice grant issuer requires. Production refuses that bootstrap outright, so
# a public demonstration has to run under this environment rather than weakening
# the production gate. Real Turnstile verification and the approved disclosure
# copy remain outstanding WP-05 work before anything runs as production.
Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  config.active_storage.service = :local

  config.assume_ssl = true
  config.force_ssl = true

  config.log_tags = [ :request_id ]
  config.logger = ActiveSupport::TaggedLogging.logger(STDOUT)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false

  config.action_mailer.default_url_options = { host: "example.com" }

  config.i18n.fallbacks = true

  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]
end
