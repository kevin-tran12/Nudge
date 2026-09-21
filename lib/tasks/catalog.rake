# CAT-SYNC-01. Entry point for the nudge-production-catalog-sync Cloud Run job
# (`bin/rails catalog:sync`).
#
# Fixture is the default and the only mode reachable without an explicit
# opt-in. Record mode requires BOTH CATALOG_SYNC_MODE=record AND a CJ
# credential present in the server-side configuration snapshot
# (Rails.application.config.x.cj, populated once from CJ_API_KEY by
# config/initializers/cj.rb). This mirrors Integrations::ElevenLabs::Adapter.build:
# the decision is read from trusted server configuration, never from a request,
# and a misconfigured deployment aborts or degrades to fixture rather than
# silently calling the provider.
#
# This file is the only place Integrations::Cj::ModePolicy::RECORD_CAPABILITY is
# handed out. ModePolicy itself still decides whether the deployment may use
# record at all (development/staging only), so an accidental production
# invocation fails closed there too.
#
# Nothing here prints, logs, or interpolates a credential: only
# `credentials_present=true/false` is ever reported.
#
# Rails loads lib/tasks/**/*.rake more than once (the engine and the
# application each load the glob), so this file deliberately defines no
# top-level constants -- the defaults live in methods instead.
module CatalogSync
  class << self
    def run(out: $stdout)
      mode = resolved_mode
      limit = integer_env("CATALOG_SYNC_PRODUCT_LIMIT", 1, Catalog::SupplierCapture::MAX_PRODUCTS)
      page_size = integer_env("CATALOG_SYNC_PAGE_SIZE", 1, Catalog::SupplierCapture::MAX_PAGE_SIZE)
      max_variants = integer_env("CATALOG_SYNC_MAX_VARIANTS", 1,
        Catalog::SupplierCapture::DEFAULT_MAX_VARIANTS_PER_PRODUCT)
      dry_run = boolean_env("CATALOG_SYNC_DRY_RUN")

      if mode == "fixture"
        out.puts(header(mode:, limit:, page_size:, max_variants:, dry_run:))
        out.puts("catalog:sync fixture mode: no supplier call and no import was made. " \
          "Set CATALOG_SYNC_MODE=record with CJ_API_KEY present to capture real data.")
        out.puts("catalog:sync summary products_imported=0 variants_imported=0 points_consumed=0 indexed=0")
        return
      end

      category, keyword = filters
      out.puts(header(mode:, limit:, page_size:, max_variants:, dry_run:, category:, keyword:))

      supplier = Supplier.find_by(key: "cj")
      abort("catalog:sync: supplier \"cj\" is not provisioned.") unless supplier

      summary = capture(supplier:, limit:, page_size:, max_variants:, category:, keyword:, dry_run:)
      indexed = dry_run ? 0 : reindex
      out.puts("catalog:sync summary #{summary} indexed=#{indexed}")
    end

    private
      def capture(supplier:, limit:, page_size:, max_variants:, category:, keyword:, dry_run:)
        Catalog::SupplierCapture.build(supplier: supplier, profile: Catalog::ImportProfiles::CJ) do |sink|
          Integrations::Cj::Adapter.new(mode: :record, deployment: Rails.env,
            capability: Integrations::Cj::ModePolicy::RECORD_CAPABILITY, raw_sink: sink)
        end.call(max_products: limit, page_size: page_size, category: category, keyword: keyword,
          max_variants_per_product: max_variants, dry_run: dry_run)
      end

      def reindex
        Search::CatalogIndexer.new(product_reader: Catalog::DatabaseProductReader.new).call.processed
      end

      # Record is selected only when the operator asked for it AND the
      # server-side configuration snapshot actually carries a credential.
      # Anything else either stays on the fixture default or aborts.
      def resolved_mode
        mode = env("CATALOG_SYNC_MODE")
        abort("catalog:sync: CATALOG_SYNC_MODE must be one of #{modes.join(', ')}.") unless modes.include?(mode)
        return mode if mode == "fixture"

        config = Rails.application.config.x.cj
        unless config.respond_to?(:credentials_present?) && config.credentials_present?
          abort("catalog:sync: CATALOG_SYNC_MODE=record requires a CJ credential " \
            "(CJ_API_KEY) to be present; credentials_present=false. Refusing to run.")
        end

        mode
      end

      def filters
        category = env("CATALOG_SYNC_CATEGORY").presence
        keyword = env("CATALOG_SYNC_KEYWORD").presence
        if category.nil? && keyword.nil?
          abort("catalog:sync: record mode needs at least one of CATALOG_SYNC_CATEGORY or CATALOG_SYNC_KEYWORD.")
        end

        [ category, keyword ]
      end

      def header(mode:, limit:, page_size:, max_variants:, dry_run:, category: nil, keyword: nil)
        "catalog:sync mode=#{mode} deployment=#{Rails.env} credentials_present=#{credentials_present?} " \
          "product_limit=#{limit} page_size=#{page_size} max_variants_per_product=#{max_variants} " \
          "category=#{category.inspect} keyword=#{keyword.inspect} dry_run=#{dry_run}"
      end

      def credentials_present?
        config = Rails.application.config.x.cj
        config.respond_to?(:credentials_present?) && config.credentials_present?
      end

      def modes
        %w[fixture record].freeze
      end

      # The default bound is chosen to fit the record ceiling. Record's ceiling
      # is 2,500 points, but product/inventory/product_list are all :catalog
      # purpose, so the binding limit is the catalog partition: 60% of 2,500 =
      # 1,500 points. Worst case for these defaults is
      #   50 (1 product_list page) + 12 x 50 (product) + 12 x 5 x 10 (inventory)
      #   = 50 + 600 + 600 = 1,250 points,
      # leaving 250 points of headroom. Raising any of these three variables
      # must be re-checked against that arithmetic.
      def defaults
        { mode: "fixture", product_limit: "12", page_size: "12", max_variants: "5",
          category: "", keyword: "", dry_run: "false" }.freeze
      end

      def env(key)
        ENV.fetch(key, defaults.fetch(key.delete_prefix("CATALOG_SYNC_").downcase.to_sym))
      end

      def integer_env(key, minimum, maximum)
        raw = env(key)
        abort("catalog:sync: #{key} must be an integer between #{minimum} and #{maximum}.") unless
          raw.match?(/\A\d{1,4}\z/) && raw.to_i.between?(minimum, maximum)

        raw.to_i
      end

      def boolean_env(key)
        raw = env(key)
        abort("catalog:sync: #{key} must be true or false.") unless %w[true false].include?(raw)

        raw == "true"
      end
  end
end

namespace :catalog do
  desc "Capture CJ supplier data into the local catalog (fixture by default; record needs explicit opt-in)"
  task sync: :environment do
    CatalogSync.run
  end
end
