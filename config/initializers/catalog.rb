# Reads the optional extra supplier asset host from ENV exactly once, at the
# Rails boundary. Every other file must depend on
# Rails.application.config.x.catalog, never on ENV directly. Unset (the
# default in every deployment) means the CJ-only media allowlist, unchanged
# from before this existed -- see Catalog::MediaHosts.
#
# Assignment is deferred to after_initialize: autoloading for app/-managed
# constants (Catalog::Config) is not yet available while
# config/initializers/*.rb run, only once the application has finished
# booting.
Rails.application.config.after_initialize do
  Rails.application.config.x.catalog = Catalog::Config.new(
    asset_host: ENV["CATALOG_ASSET_HOST"].presence
  ).freeze
end
