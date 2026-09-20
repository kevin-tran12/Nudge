require "uri"

module Catalog
  class FixtureProductReader < ProductReader
    DEFAULT_PRODUCT_IDS = [
      "00001234", "00002001", "00002002", "00002003",
      "00002004", "00002005", "00002006", "00002007"
    ].freeze
    # Verified against live CJ responses: product detail serves its images from
    # oss-cf.cjdropshipping.com, so an allowlist without it rejects every real
    # product. All three are first-party supplier CDN hosts; the rule itself is
    # unchanged (exact host match, HTTPS only, no userinfo, query or fragment).
    APPROVED_MEDIA_HOSTS = %w[
      cf.cjdropshipping.com
      oss-cf.cjdropshipping.com
      cc-west-usa.oss-us-west-1.aliyuncs.com
    ].freeze
    ID_PATTERN = /\A[A-Za-z0-9_{}-]+\z/
    CURSOR_PATTERN = /\A(?:0|[1-9]\d{0,5})\z/

    def initialize(adapter: Integrations::Cj::Adapter.new, product_ids: DEFAULT_PRODUCT_IDS)
      unless product_ids.is_a?(Array) && product_ids.size.between?(1, 100)
        raise Error.new(:invalid_input)
      end

      @adapter = adapter
      @product_ids = product_ids.map { |id| identifier(id) }.uniq.sort.freeze
      raise Error.new(:invalid_input) unless @product_ids.size == product_ids.size
    end

    def list(limit: MAX_LIMIT, cursor: nil)
      validate_limit!(limit)
      offset = cursor_offset(cursor)
      raise Error.new(:invalid_input) if offset > @product_ids.length

      ids = @product_ids.slice(offset, limit) || []
      items = ids.map { |id| read_product(id) }
      next_offset = offset + ids.length
      next_cursor = next_offset < @product_ids.length ? next_offset.to_s : nil
      ProductReader.deep_freeze(Page.new(items: items, next_cursor: next_cursor))
    end

    def detail(id:)
      catalog_id = identifier(id)
      raise Error.new(:not_found) unless @product_ids.bsearch { |known| known >= catalog_id } == catalog_id

      read_product(catalog_id)
    end

    private
      def read_product(id)
        result = @adapter.product(product_id: id)
        source = result.value
        raise Error.new(:source_unavailable) unless source.external_id == id
        observed_at = observed_time(result)
        images, images_state = images(source.image_urls)
        variants = source.variants.map { |variant| variant_projection(variant, id, observed_at) }.sort_by(&:id)
        raise Error.new(:source_unavailable) unless variants.map(&:id).uniq.size == variants.size

        ProductReader.deep_freeze(Product.new(id: identifier(source.external_id), sku: optional_reference(source.sku),
          title: plain_text(source.title, 200), description: optional_plain_text(source.description, 16_384),
          images: images, images_state: images_state, variants: variants,
          freshness: Freshness.new(state: :observed, observed_at: observed_at)))
      rescue Integrations::Cj::Error => error
        raise Error.new(error.code == :not_found ? :not_found : :source_unavailable,
          retryable: error.retryable?), cause: nil
      rescue Error
        raise
      rescue NoMethodError, TypeError, ArgumentError
        raise Error.new(:source_unavailable), cause: nil
      end

      def variant_projection(source, product_id, price_observed_at)
        raise Error.new(:source_unavailable) unless source.product_id == product_id
        id = identifier(source.external_id)
        Variant.new(id: id, sku: optional_reference(source.sku), title: optional_plain_text(source.title, 200),
          price: price(source.price, price_observed_at), availability: availability(id),
          weight: measurement(source.weight), length: measurement(source.length),
          width: measurement(source.width), height: measurement(source.height))
      end

      def price(source, observed_at)
        freshness = Freshness.new(state: :observed, observed_at: observed_at)
        return Price.new(state: :unknown, amount_minor: nil, currency: nil, freshness: freshness) if source.nil?

        unless source.amount_minor.is_a?(Integer) && source.amount_minor >= 0 &&
            safe_string_encoding?(source.currency, min: 3, max: 3) && source.currency.match?(/\A[A-Z]{3}\z/)
          raise Error.new(:source_unavailable)
        end
        Price.new(state: :known, amount_minor: source.amount_minor,
          currency: plain_string(source.currency), freshness: freshness)
      end

      def availability(variant_id)
        result = @adapter.inventory(variant_id: variant_id)
        rows = result.value
        unless rows.is_a?(Array) && rows.all? { |row| row.variant_id == variant_id }
          raise Error.new(:source_unavailable)
        end

        observed_at = observed_time(result)
        freshness = Freshness.new(state: :observed, observed_at: observed_at)
        return Availability.new(state: :unknown, quantity: nil, reason: :not_observed,
          freshness: freshness) if rows.empty? || rows.any? { |row| row.total_quantity.nil? }

        quantities = rows.map(&:total_quantity)
        raise Error.new(:source_unavailable) unless quantities.all? { |quantity| quantity.is_a?(Integer) && quantity >= 0 }

        total = quantities.sum
        Availability.new(state: total.positive? ? :available : :unavailable,
          quantity: total, reason: :observed, freshness: freshness)
      rescue Integrations::Cj::Error => error
        reason = [ :fixture_miss, :not_found ].include?(error.code) ? :not_observed : :source_error
        Availability.new(state: :unknown, quantity: nil, reason: reason,
          freshness: Freshness.new(state: :unknown, observed_at: nil))
      end

      def measurement(source)
        return Measurement.new(state: :unknown, value: nil, unit: nil) if source.nil?
        unless source.value.is_a?(Numeric) && source.value >= 0 &&
            safe_string_encoding?(source.unit, min: 1, max: 20)
          raise Error.new(:source_unavailable)
        end
        Measurement.new(state: :known, value: source.value, unit: plain_string(source.unit))
      end

      def images(source)
        return [ [], :unknown ] if source.nil?
        raise Error.new(:source_unavailable) unless source.is_a?(Array) && source.size <= 50

        rows = source.each_with_index.map { |url, position| Image.new(url: safe_media_url(url), position: position) }
        [ rows, :known ]
      end

      def safe_media_url(value)
        raise Error.new(:source_unavailable) unless safe_string_encoding?(value, min: 1, max: 2048)
        uri = URI.parse(value)
        unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? &&
            uri.fragment.nil? && APPROVED_MEDIA_HOSTS.include?(uri.host) &&
            uri.path.start_with?("/") && !uri.path.split("/").include?("..") && !uri.path.include?("%")
          raise Error.new(:source_unavailable)
        end
        plain_string(value)
      rescue URI::InvalidURIError, Encoding::CompatibilityError
        raise Error.new(:source_unavailable), cause: nil
      end

      def plain_text(value, limit)
        unless safe_string_encoding?(value, min: 1, max: limit)
          raise Error.new(:source_unavailable)
        end
        sanitized = ActionView::Base.full_sanitizer.sanitize(value).to_s
        raise Error.new(:source_unavailable) if sanitized.empty? || sanitized.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
        plain_string(sanitized)
      end

      def optional_plain_text(value, limit)
        value.nil? ? nil : plain_text(value, limit)
      end

      def optional_reference(value)
        return if value.nil?
        unless safe_string_encoding?(value, min: 1, max: 200) &&
            !value.match?(/[\u0000-\u001f\u007f]/)
          raise Error.new(:source_unavailable)
        end
        plain_string(value)
      end

      def observed_time(result)
        value = result.provenance.observed_at
        raise Error.new(:source_unavailable) unless value.is_a?(Time)
        value
      end

      def identifier(value)
        unless safe_string_encoding?(value, min: 1, max: 200) && value.match?(ID_PATTERN)
          raise Error.new(:invalid_input)
        end
        plain_string(value)
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
          value.valid_encoding? &&
          value.bytesize.between?(min, max)
      end

      def plain_string(value)
        String.new(value)
      end
  end
end
