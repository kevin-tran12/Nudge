require "uri"

module Catalog
  # Reads the real, imported catalog (DB-03/DB-04 tables) through the same
  # ProductReader contract as Catalog::FixtureProductReader. Rails/PostgreSQL
  # are the source of truth here, so unlike the fixture reader there is no
  # remote adapter call that can fail; instead, "no evidence" (no price,
  # inventory, or media observation) is the normal, expected shape and is
  # always projected as the DTOs explicit :unknown state, never a fabricated
  # value.
  #
  # Supplier-authored text (title/description/sku) is stored verbatim by
  # Catalog::ArtifactImporter and is sanitized here, at read time, exactly as
  # Catalog::FixtureProductReader sanitizes it: HTML is stripped to plain
  # text and image URLs are checked against the same approved HTTPS media
  # hosts. Rows that fail that validation raise source_unavailable, the same
  # failure code the fixture reader raises for malformed data.
  class DatabaseProductReader < ProductReader
    PRICE_KIND = "supplier_sell"
    ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    CURSOR_PATTERN = /\A(?:0|[1-9]\d{0,5})\z/

    def list(limit: MAX_LIMIT, cursor: nil)
      validate_limit!(limit)
      offset = cursor_offset(cursor)

      rows = ::Product.order(:created_at, :id).offset(offset).limit(limit + 1).to_a
      page_rows = rows.first(limit)
      next_offset = offset + page_rows.length
      next_cursor = rows.length > limit ? next_offset.to_s : nil

      items = build_products(page_rows)
      ProductReader.deep_freeze(Page.new(items: items, next_cursor: next_cursor))
    end

    def detail(id:)
      catalog_id = identifier(id)
      record = ::Product.find_by(public_id: catalog_id)
      raise Error.new(:not_found) unless record

      build_products([ record ]).first
    end

    private
      def build_products(records)
        return [] if records.empty?

        product_ids = records.map(&:id)
        supplier_products = load_supplier_products(product_ids)
        product_freshness = load_product_freshness(supplier_products)
        variants_by_product = load_variants_by_product(product_ids)
        variant_ids = variants_by_product.values.flatten(1).map(&:id)
        supplier_variants = load_supplier_variants(variant_ids)
        supplier_variant_ids = supplier_variants.values.map(&:id)
        prices = load_latest_prices(supplier_variant_ids)
        availabilities = load_availabilities(supplier_variant_ids)
        media_by_product = load_media(product_ids)

        records.map do |record|
          build_product(record, supplier_products:, product_freshness:,
            variants: variants_by_product.fetch(record.id, []), supplier_variants:,
            prices:, availabilities:, media_by_product:)
        end
      end

      def build_product(record, supplier_products:, product_freshness:, variants:, supplier_variants:,
        prices:, availabilities:, media_by_product:)
        supplier_product = supplier_products[record.id]
        images, images_state = images_for(media_by_product.fetch(record.id, []))
        variant_dtos = variants.sort_by(&:id).map do |variant_record|
          variant_projection(variant_record, supplier_variants:, prices:, availabilities:)
        end

        ProductReader.deep_freeze(Product.new(
          id: identifier(record.public_id),
          sku: optional_reference(supplier_product&.external_sku),
          title: plain_text(record.title, 200),
          description: blank_to_nil(record.description).nil? ? nil : optional_plain_text(record.description, 16_384),
          images: images, images_state: images_state, variants: variant_dtos,
          freshness: product_freshness.fetch(record.id, Freshness.new(state: :unknown, observed_at: nil))
        ))
      end

      def variant_projection(record, supplier_variants:, prices:, availabilities:)
        supplier_variant = supplier_variants[record.id]
        supplier_variant_id = supplier_variant&.id
        Variant.new(id: identifier(record.public_id), sku: optional_reference(supplier_variant&.external_variant_sku),
          title: plain_text(record.title, 200),
          price: price_for(supplier_variant_id, prices),
          availability: availability_for(supplier_variant_id, availabilities),
          weight: measurement(record.weight_value, record.weight_unit),
          length: measurement(record.length_value, record.dimension_unit),
          width: measurement(record.width_value, record.dimension_unit),
          height: measurement(record.height_value, record.dimension_unit))
      end

      def price_for(supplier_variant_id, prices)
        observation = supplier_variant_id && prices[supplier_variant_id]
        unless observation
          return Price.new(state: :unknown, amount_minor: nil, currency: nil,
            freshness: Freshness.new(state: :unknown, observed_at: nil))
        end

        Price.new(state: :known, amount_minor: observation.amount_minor,
          currency: plain_string(observation.currency),
          freshness: Freshness.new(state: :observed, observed_at: observation.observed_at))
      end

      def availability_for(supplier_variant_id, availabilities)
        rows = supplier_variant_id && availabilities[supplier_variant_id]
        if rows.blank? || rows.any? { |row| row.total_quantity.nil? }
          return Availability.new(state: :unknown, quantity: nil, reason: :not_observed,
            freshness: Freshness.new(state: :unknown, observed_at: nil))
        end

        total = rows.sum(&:total_quantity)
        observed_at = rows.map(&:observed_at).max
        Availability.new(state: total.positive? ? :available : :unavailable, quantity: total, reason: :observed,
          freshness: Freshness.new(state: :observed, observed_at: observed_at))
      end

      def measurement(value, unit)
        return Measurement.new(state: :unknown, value: nil, unit: nil) if value.nil? || unit.nil?
        unless value.is_a?(Numeric) && value >= 0 && safe_string_encoding?(unit, min: 1, max: 20)
          raise Error.new(:source_unavailable)
        end

        Measurement.new(state: :known, value: value, unit: plain_string(unit))
      end

      def images_for(media_records)
        return [ [], :unknown ] if media_records.empty?

        rows = media_records.each_with_index.map do |media, position|
          Image.new(url: safe_media_url(media.sanitized_url), position: position)
        end
        [ rows, :known ]
      end

      def load_supplier_products(product_ids)
        ::SupplierProduct.where(product_id: product_ids).select(:product_id, :external_sku, :latest_observation_id)
          .index_by(&:product_id)
      end

      def load_product_freshness(supplier_products)
        observation_ids = supplier_products.values.filter_map(&:latest_observation_id)
        return {} if observation_ids.empty?

        observed_at_by_id = ::SupplierObservation.where(id: observation_ids).pluck(:id, :observed_at).to_h
        supplier_products.each_with_object({}) do |(product_id, supplier_product), result|
          observed_at = observed_at_by_id[supplier_product.latest_observation_id]
          next unless observed_at

          result[product_id] = Freshness.new(state: :observed, observed_at: observed_at)
        end
      end

      def load_variants_by_product(product_ids)
        ::ProductVariant.where(product_id: product_ids).order(:product_id, :id).to_a.group_by(&:product_id)
      end

      def load_supplier_variants(variant_ids)
        return {} if variant_ids.empty?

        ::SupplierVariant.where(product_variant_id: variant_ids)
          .select(:product_variant_id, :id, :external_variant_sku).index_by(&:product_variant_id)
      end

      def load_latest_prices(supplier_variant_ids)
        return {} if supplier_variant_ids.empty?

        ::PriceObservation.select("DISTINCT ON (supplier_variant_id) price_observations.*")
          .where(supplier_variant_id: supplier_variant_ids, price_kind: PRICE_KIND)
          .order(:supplier_variant_id, observed_at: :desc, id: :desc)
          .index_by(&:supplier_variant_id)
      end

      def load_availabilities(supplier_variant_ids)
        return {} if supplier_variant_ids.empty?

        ::InventoryObservation.select("DISTINCT ON (supplier_variant_id, supplier_warehouse_id) inventory_observations.*")
          .where(supplier_variant_id: supplier_variant_ids)
          .order(:supplier_variant_id, :supplier_warehouse_id, observed_at: :desc, id: :desc)
          .group_by(&:supplier_variant_id)
      end

      def load_media(product_ids)
        ::CatalogMedia.where(product_id: product_ids, status: "active", kind: "image")
          .order(:product_id, :position, :id).to_a.group_by(&:product_id)
      end

      def safe_media_url(value)
        raise Error.new(:source_unavailable) unless safe_string_encoding?(value, min: 1, max: 2048)
        uri = URI.parse(value)
        unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? &&
            uri.fragment.nil? && FixtureProductReader::APPROVED_MEDIA_HOSTS.include?(uri.host) &&
            uri.path.start_with?("/") && !uri.path.split("/").include?("..") && !uri.path.include?("%")
          raise Error.new(:source_unavailable)
        end
        plain_string(value)
      rescue URI::InvalidURIError, Encoding::CompatibilityError
        raise Error.new(:source_unavailable), cause: nil
      end

      def plain_text(value, limit)
        raise Error.new(:source_unavailable) unless safe_string_encoding?(value, min: 1, max: limit)

        sanitized = ActionView::Base.full_sanitizer.sanitize(value).to_s
        raise Error.new(:source_unavailable) if sanitized.empty? || sanitized.match?(/[ --]/)
        plain_string(sanitized)
      end

      def optional_plain_text(value, limit)
        value.nil? ? nil : plain_text(value, limit)
      end

      def optional_reference(value)
        return if value.nil?
        unless safe_string_encoding?(value, min: 1, max: 200) && !value.match?(/[ -]/)
          raise Error.new(:source_unavailable)
        end
        plain_string(value)
      end

      def blank_to_nil(value)
        value.nil? || value.empty? ? nil : value
      end

      def identifier(value)
        string_value = value.is_a?(String) ? value : value.to_s
        unless safe_string_encoding?(string_value, min: 1, max: 200) && string_value.match?(ID_PATTERN)
          raise Error.new(:invalid_input)
        end
        plain_string(string_value)
      end

      def validate_limit!(limit)
        raise Error.new(:invalid_input) unless limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)
      end

      def cursor_offset(cursor)
        return 0 if cursor.nil?
        unless safe_string_encoding?(cursor, min: 1, max: 6) && cursor.match?(CURSOR_PATTERN)
          raise Error.new(:invalid_input)
        end
        cursor.to_i
      end

      def safe_string_encoding?(value, min:, max:)
        value.is_a?(String) && [ Encoding::UTF_8, Encoding::US_ASCII ].include?(value.encoding) &&
          value.valid_encoding? && value.bytesize.between?(min, max)
      end

      def plain_string(value)
        String.new(value)
      end
  end
end
