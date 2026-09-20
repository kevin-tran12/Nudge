# STRIPE-SPECIFIC: removable provider integration; do not place domain logic here.
#
# Reads Stripe credentials from ENV exactly once, at the Rails boundary. Every
# other file must depend on Rails.application.config.x.stripe, never on ENV
# directly. Missing credentials never crash boot: fixture mode (the default in
# every deployment except when explicitly opted into, see
# Integrations::Stripe::ModePolicy) does not need them, and test-mode transport
# degrades to fixture rather than attempting an unauthenticated call.
#
# STRIPE_MODE selects the transport and is read here exactly once: only the
# literal "test_mode" opts into Stripe TEST-mode transport, anything else (and
# an unset variable) is fixture. There is no live-money mode to select.
#
# Assignment is deferred to after_initialize: autoloading for app/-managed
# constants (Integrations::Stripe::Config) is not yet available while
# config/initializers/*.rb run, only once the application has finished booting.
Rails.application.config.after_initialize do
  Rails.application.config.x.stripe = Integrations::Stripe::Config.new(
    secret_key: ENV["STRIPE_SECRET_KEY"].presence,
    webhook_secret: ENV["STRIPE_WEBHOOK_SECRET"].presence,
    mode: ENV.fetch("STRIPE_MODE", "fixture")
  ).freeze
end
