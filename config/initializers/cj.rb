# Reads the CJ credential from ENV exactly once, at the Rails boundary. Every
# other file must depend on Rails.application.config.x.cj, never on ENV
# directly. A missing credential never crashes boot: fixture mode (the only
# mode reachable without an explicit ModePolicy capability sentinel from
# trusted server code, see Integrations::Cj::ModePolicy) does not need it, and
# a non-fixture mode fails closed with :missing_credentials-style errors on
# first use rather than silently calling CJ unauthenticated.
#
# Assignment is deferred to after_initialize: autoloading for app/-managed
# constants (Integrations::Cj::Config) is not yet available while
# config/initializers/*.rb run, only once the application has finished booting.
Rails.application.config.after_initialize do
  Rails.application.config.x.cj = Integrations::Cj::Config.new(
    api_key: ENV["CJ_API_KEY"].presence
  ).freeze
end
