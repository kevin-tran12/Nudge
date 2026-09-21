# Reads Prodigi credentials from ENV exactly once, at the Rails boundary.
# Every other file must depend on Rails.application.config.x.prodigi, never
# on ENV directly. Missing credentials never crash boot: fixture mode (the
# default in every deployment except when explicitly opted into, see
# Integrations::Prodigi::ModePolicy) does not need them, and sandbox
# construction fails closed rather than attempting an unauthenticated call.
#
# PRODIGI_MODE selects the transport and is read here exactly once: only the
# literal "sandbox" opts into Prodigi sandbox transport, anything else (and
# an unset variable) is fixture. There is no live-fulfillment mode to
# select -- a live Prodigi order spends real money, so adding that path is a
# small, explicit, separately-approved change, not a spelling of this ENV var.
#
# Assignment is deferred to after_initialize: autoloading for app/-managed
# constants (Integrations::Prodigi::Config) is not yet available while
# config/initializers/*.rb run, only once the application has finished
# booting.
Rails.application.config.after_initialize do
  Rails.application.config.x.prodigi = Integrations::Prodigi::Config.new(
    api_key: ENV["PRODIGI_API_KEY"].presence,
    mode: ENV.fetch("PRODIGI_MODE", "fixture")
  ).freeze
end
