module Catalog
  # CAT-MEDIA-01 (Prodigi phase). Catalog::FixtureProductReader::APPROVED_MEDIA_HOSTS
  # used to be the one place the CJ CDN allowlist lived, and both
  # ArtifactImporter's media-url validator and Catalog::DatabaseProductReader
  # enforced it by referencing that constant directly -- a second supplier's
  # media host could never pass. This centralizes it and adds one optional
  # extra host read from server configuration, so an unset (or blank)
  # asset_host is byte-for-byte the CJ-only list from before.
  module MediaHosts
    CJ_HOSTS = %w[
      cf.cjdropshipping.com
      oss-cf.cjdropshipping.com
      oss.cjdropshipping.com
      cc-west-usa.oss-us-west-1.aliyuncs.com
      cj-product-center.oss-accelerate.aliyuncs.com
    ].freeze

    def self.approved
      asset_host = Rails.application.config.x.catalog&.asset_host
      asset_host.present? ? (CJ_HOSTS + [ asset_host ]).freeze : CJ_HOSTS
    end
  end
end
