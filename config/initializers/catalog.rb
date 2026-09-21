# Reads the optional extra supplier asset host from ENV exactly once, at the
# Rails boundary. Every other file must depend on
# Rails.application.config.x.catalog, never on ENV directly. Unset (the
# default in every deployment) means the CJ-only media allowlist, unchanged
# from before this existed -- see Catalog::MediaHosts.
#
# Assigned synchronously here, NOT deferred to after_initialize the way
# config/initializers/stripe.rb defers to Integrations::Stripe::Config:
# eager_load! -- which freezes Catalog::FixtureProductReader::APPROVED_MEDIA_HOSTS
# via Catalog::MediaHosts.approved at class-definition time -- runs BEFORE
# after_initialize in any eager-loaded environment (production, and CI per
# config/environments/test.rb). Deferring this assignment left that constant
# permanently pinned to the CJ-only list no matter what CATALOG_ASSET_HOST
# was set to. Defined as an anonymous Data type inline rather than an
# app/-autoloaded Catalog::Config class, since app/-managed constants are not
# yet resolvable this early in boot.
Rails.application.config.x.catalog = Data.define(:asset_host).new(
  asset_host: ENV["CATALOG_ASSET_HOST"].presence
).freeze
