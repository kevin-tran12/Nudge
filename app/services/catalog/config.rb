module Catalog
  # Frozen snapshot of ENV read exactly once, at the Rails boundary, by
  # config/initializers/catalog.rb. Every other file depends on this object
  # (Rails.application.config.x.catalog) and never reads ENV directly.
  Config = Data.define(:asset_host)
end
