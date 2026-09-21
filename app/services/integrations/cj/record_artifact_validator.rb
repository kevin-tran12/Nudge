require "digest"
require "bigdecimal"
require "json"
require "time"

module Integrations
  module Cj
    # Validates already captured CJ response bytes before a later, explicitly
    # authorized record runner may write them. This boundary is deliberately
    # offline: it owns no transport, credentials, mode, budget, clock, or path.
    class RecordArtifactValidator
      FIXTURE_VERSION = 1
      MAX_ARTIFACT_BYTES = 1_048_576
      ARTIFACT_KEYS = %w[fixture_version observed_at request response].freeze
      OPERATIONS = %i[product inventory freight product_list].freeze
      IDENTIFIER = /\A[A-Za-z0-9_{}-]+\z/
      COUNTRY = /\A[A-Z]{2}\z/
      FORBIDDEN_KEYS = %w[
        accesstoken refreshtoken openid authorization sign signature apikey
        email phone recipientname customername address address1 address2 zip
        zipcode postalcode token credential secret password
      ].freeze
      # Captured from live responses on 2026-09-20: every CJ reply also carries
      # pointsInfo (the quota accounting for the call) and success alongside the
      # documented envelope.
      RESPONSE_KEYS = %w[code data message pointsInfo requestId result success].freeze
      # PRODUCT_KEYS, VARIANT_KEYS, PRODUCT_LIST_KEYS, PRODUCT_LIST_ITEM_KEYS and
      # INVENTORY_KEYS are the complete field sets captured from live
      # authenticated CJ responses on 2026-09-20 (product/query,
      # product/list, product/stock/queryByVid). They are evidenced, not
      # inferred: the earlier sets were derived from hand-sanitized fixtures and
      # were narrower than reality, so every genuine response was rejected.
      # These stay strict allowlists -- only reviewed fields are ever persisted
      # as evidence -- so a field CJ adds later fails closed until it is
      # captured, reviewed, and added here.
      PRODUCT_KEYS = %w[
        addMarkStatus bigImage categoryId categoryName createrTime customizationJson1 customizationJson2
        customizationJson3 customizationJson4 customizationVersion description entryCode entryName
        entryNameEn isTestProduct listedNum materialKey materialKeySet materialName materialNameEn
        materialNameEnSet materialNameSet packingKey packingKeySet packingName packingNameEn
        packingNameEnSet packingNameSet packingWeight pid productImage productImageSet productKey
        productKeyEn productKeyEnSet productKeySet productName productNameEn productNameSet productPro
        productProEn productProEnSet productProSet productSku productType productUnit productVideo
        productWeight sellPrice sourceFrom status suggestSellPrice supplierId supplierName variants
      ].freeze
      VARIANT_KEYS = %w[
        barcode combineNum combineVariants createTime inventories inventoryNum pid variantHeight
        variantImage variantKey variantLength variantName variantNameEn variantProperty variantSellPrice
        variantSku variantStandard variantSugSellPrice variantUnit variantVolume variantWeight
        variantWidth vid
      ].freeze
      PRODUCT_LIST_KEYS = %w[list pageNum pageSize total].freeze
      PRODUCT_LIST_ITEM_KEYS = %w[
        addMarkStatus categoryId categoryName createTime customizationVersion isFreeShipping isTestProduct
        isVideo listedNum listingCount oneCategoryId oneCategoryName pid productImage productName
        productNameEn productSku productType productUnit productWeight remark saleStatus sellPrice
        shippingCountryCodes sourceFrom supplierId supplierName threeCategoryName twoCategoryId
        twoCategoryName
      ].freeze
      INVENTORY_KEYS = %w[
        areaEn areaId cjInventoryNum countryCode factoryInventoryNum stock storageNum totalInventoryNum vid
      ].freeze
      STOCK_KEYS = %w[factoryInventory inventory stockId].freeze
      FREIGHT_KEYS = %w[
        clearanceOperationFee logisticAging logisticName logisticPrice taxesFee totalPostageFee
      ].freeze
      ACTIVE_ELEMENTS = "script, style, template, iframe, object".freeze
      # Persisted evidence must not be able to execute or exfiltrate, but real
      # CJ descriptions are ordinary marketing HTML (<img src>, <br/>, <b>,
      # style="max-width:100%"). Rejecting every attribute made every genuine
      # product unstorable, so only the attributes that are themselves an
      # execution or navigation vector are refused:
      #   * any event handler, i.e. any name beginning "on";
      #   * srcdoc / formaction / xlink:href;
      #   * any value whose URL scheme is one of DANGEROUS_SCHEMES.
      # Benign presentational attributes, and href/src to an ordinary
      # http(s) or relative URL, are kept: they are inert data, and the
      # normalizer independently re-checks every media URL against the media
      # host allowlist before anything is displayed.
      DANGEROUS_ATTRIBUTES = %w[srcdoc formaction xlink:href].freeze
      DANGEROUS_SCHEMES = %w[javascript vbscript data blob filesystem about].freeze
      # Browsers strip ASCII control characters (tab, CR, LF, NUL) out of a URL
      # before resolving its scheme, so "java\tscript:" and "JaVaScRiPt:" both
      # execute. Normalize the same way before comparing.
      SCHEME_NOISE = Regexp.new("[\u0000-\u001f\u007f]").freeze
      # Bounded at the largest integer a JSON double round-trips exactly
      # (2**53 - 1). The previous ceiling of 1e10 rejected every real CJ
      # response, whose createTime is a millisecond epoch around 1.79e12.
      MAX_ABSOLUTE_NUMBER = BigDecimal("9007199254740991").freeze
      MIN_DECIMAL_EXPONENT = -24
      MAX_LIST_PAGE_SIZE = 200
      MAX_FILTER_BYTES = 100
      CONTROL_CHARACTERS = Regexp.new("[\u0000-\u001f\u007f]").freeze

      class DuplicateKey < StandardError; end

      class UniqueKeyHash < Hash
        def []=(key, value)
          raise DuplicateKey if key?(key)

          super
        end
      end

      Result = Data.define(:operation, :artifact_bytes, :artifact_sha256, :normalized) do
        def provenance
          normalized.provenance
        end

        def inspect
          "#<#{self.class.name} operation=#{operation.inspect} fixture_version=#{FIXTURE_VERSION} " \
            "artifact_sha256=#{artifact_sha256}>"
        end

        def to_s
          inspect
        end

        def as_json(*)
          { "operation" => operation.to_s, "fixture_version" => FIXTURE_VERSION,
            "artifact_sha256" => artifact_sha256 }
        end

        def to_json(...)
          as_json.to_json(...)
        end

        def encode_with(*)
          raise TypeError, "CJ record artifact serialization is disabled"
        end

        def marshal_dump
          raise TypeError, "CJ record artifact serialization is disabled"
        end
      end

      def initialize(normalizer: Normalizer.new)
        raise Error.new(:invalid_input), cause: nil unless normalizer.respond_to?(:call)

        @normalizer = normalizer
      end

      def call(operation:, request:, raw_body:, observed_at:)
        validate_operation!(operation)
        request_copy = validate_request!(operation, request)
        observed_at_copy = validate_observed_at!(observed_at)
        response, json_body = parse_response!(raw_body)
        reject_forbidden_keys!(response)
        validate_numbers!(response)

        normalized = @normalizer.call(operation:, body: json_body, request: request_copy,
          observed_at: observed_at_copy)
        validate_response_shape!(operation, response)
        reject_active_content!(response)
        response.delete("message")

        artifact_bytes = encode_json(
          "fixture_version" => FIXTURE_VERSION,
          "observed_at" => observed_at_copy,
          "request" => canonicalize(request_copy),
          "response" => canonicalize(response)
        ).freeze
        artifact_sha256 = Digest::SHA256.hexdigest(artifact_bytes).freeze
        provenance = normalized.provenance.with(source: :record_artifact, payload_sha256: artifact_sha256)
        normalized = Contracts.deep_freeze(
          Contracts::Result.new(value: normalized.value, provenance:, request: normalized.request)
        )
        Result.new(operation:, artifact_bytes:, artifact_sha256:, normalized:).freeze
      rescue Error => error
        raise Error.new(error.code), cause: nil
      rescue DuplicateKey, JSON::ParserError, JSON::NestingError, EncodingError, ArgumentError, KeyError, TypeError
        raise Error.new(:malformed_response), cause: nil
      rescue StandardError
        raise Error.new(:malformed_response), cause: nil
      end

      # Replays untrusted, in-memory v1 bytes through the capture boundary. The
      # extra nesting level belongs to the envelope; the provider body retains
      # its own smaller byte and nesting limits. No path or IO is accepted.
      def read(operation:, artifact_bytes:)
        validate_operation!(operation)
        artifact, = parse_json!(artifact_bytes, max_bytes: MAX_ARTIFACT_BYTES, max_nesting: 13)
        unless artifact.keys.sort == ARTIFACT_KEYS &&
            artifact["fixture_version"].instance_of?(Integer) && artifact["fixture_version"] == FIXTURE_VERSION
          raise Error.new(:malformed_response)
        end
        validate_numbers!(artifact)

        call(operation:, request: canonicalize(artifact.fetch("request")),
          raw_body: encode_json(artifact.fetch("response")), observed_at: artifact.fetch("observed_at"))
      rescue Error => error
        raise Error.new(error.code), cause: nil
      rescue StandardError
        raise Error.new(:malformed_response), cause: nil
      end

      private
        def validate_operation!(operation)
          raise Error.new(:invalid_input) unless OPERATIONS.include?(operation)
        end

        def validate_request!(operation, request)
          raise Error.new(:invalid_input) unless request.instance_of?(Hash)

          case operation
          when :product
            exact_keys!(request, %w[product_id])
            identifier!(request.fetch("product_id"))
          when :inventory
            exact_keys!(request, %w[variant_id])
            identifier!(request.fetch("variant_id"))
          when :freight
            exact_keys!(request, %w[destination_country items origin_country])
            country!(request.fetch("origin_country"))
            country!(request.fetch("destination_country"))
            items = request.fetch("items")
            raise Error.new(:invalid_input) unless items.instance_of?(Array) && items.size.between?(1, 100)

            ids = items.map do |item|
              raise Error.new(:invalid_input) unless item.instance_of?(Hash)

              exact_keys!(item, %w[quantity variant_id])
              identifier!(item.fetch("variant_id"))
              quantity = item.fetch("quantity")
              raise Error.new(:invalid_input) unless quantity.is_a?(Integer) && quantity.between?(1, 10_000)

              item.fetch("variant_id")
            end
            raise Error.new(:invalid_input) unless ids.uniq.size == ids.size
          when :product_list
            exact_keys!(request, %w[categoryId keyword pageNum pageSize])
            page = request.fetch("pageNum")
            page_size = request.fetch("pageSize")
            unless page.instance_of?(Integer) && page >= 1 && page_size.instance_of?(Integer) &&
                page_size.between?(1, MAX_LIST_PAGE_SIZE)
              raise Error.new(:invalid_input)
            end

            category = request.fetch("categoryId")
            keyword = request.fetch("keyword")
            raise Error.new(:invalid_input) if category.nil? && keyword.nil?

            [ category, keyword ].compact.each { |filter| filter_text!(filter) }
          end

          canonicalize(request)
        end

        def validate_observed_at!(observed_at)
          unless observed_at.is_a?(String) && observed_at.encoding == Encoding::UTF_8 && observed_at.valid_encoding? &&
              observed_at.bytesize.between?(1, 64)
            raise Error.new(:invalid_input)
          end

          parsed = Time.iso8601(observed_at)
          raise Error.new(:invalid_input) unless observed_at == parsed.utc.iso8601 && parsed.utc_offset.zero?

          observed_at.dup.freeze
        rescue ArgumentError
          raise Error.new(:invalid_input), cause: nil
        end

        def parse_response!(raw_body)
          parse_json!(raw_body, max_bytes: Normalizer::MAX_BODY_BYTES, max_nesting: 12)
        end

        def parse_json!(raw_body, max_bytes:, max_nesting:)
          unless raw_body.is_a?(String) && raw_body.bytesize <= max_bytes
            raise Error.new(:malformed_response)
          end

          json_body = raw_body.dup.force_encoding(Encoding::UTF_8)
          raise Error.new(:malformed_response) unless json_body.valid_encoding?

          response = JSON.parse(json_body, max_nesting:, object_class: UniqueKeyHash,
            decimal_class: BigDecimal)
          raise Error.new(:malformed_response) unless response.instance_of?(UniqueKeyHash)

          [ response, json_body ]
        end

        def validate_response_shape!(operation, response)
          allowed_keys!(response, RESPONSE_KEYS)
          data = response.fetch("data")
          case operation
          when :product
            object!(data, PRODUCT_KEYS)
            array = data.fetch("variants")
            raise Error.new(:malformed_response) unless array.is_a?(Array)
            array.each { |variant| object!(variant, VARIANT_KEYS) }
          when :inventory
            raise Error.new(:malformed_response) unless data.is_a?(Array)
            data.each do |inventory|
              object!(inventory, INVENTORY_KEYS)
              next if inventory["stock"].nil?

              raise Error.new(:malformed_response) unless inventory["stock"].is_a?(Array)
              inventory["stock"].each { |stock| object!(stock, STOCK_KEYS) }
            end
          when :freight
            raise Error.new(:malformed_response) unless data.is_a?(Array)
            data.each { |quote| object!(quote, FREIGHT_KEYS) }
          when :product_list
            object!(data, PRODUCT_LIST_KEYS)
            rows = data.fetch("list")
            raise Error.new(:malformed_response) unless rows.is_a?(Array)
            rows.each { |row| object!(row, PRODUCT_LIST_ITEM_KEYS) }
          end
        end

        def reject_forbidden_keys!(root)
          pending = [ root ]
          until pending.empty?
            value = pending.pop
            case value
            when Hash
              value.each do |key, child|
                normalized_key = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
                raise Error.new(:malformed_response) if FORBIDDEN_KEYS.include?(normalized_key)
                pending << child
              end
            when Array
              pending.concat(value)
            end
          end
        end

        def validate_numbers!(root)
          pending = [ root ]
          until pending.empty?
            value = pending.pop
            case value
            when Hash then pending.concat(value.values)
            when Array then pending.concat(value)
            when Integer
              raise Error.new(:malformed_response) if value.abs > MAX_ABSOLUTE_NUMBER
            when BigDecimal
              unless value.finite? && value.abs <= MAX_ABSOLUTE_NUMBER &&
                  (value.zero? || value.exponent >= MIN_DECIMAL_EXPONENT)
                raise Error.new(:malformed_response)
              end
            end
          end
        end

        def reject_active_content!(root)
          pending = [ root ]
          until pending.empty?
            value = pending.pop
            case value
            when Hash then pending.concat(value.values)
            when Array then pending.concat(value)
            when String
              next unless value.include?("<") || value.include?(">")

              fragment = Loofah.html5_fragment(value)
              raise Error.new(:malformed_response) if fragment.at_css(ACTIVE_ELEMENTS)
              fragment.traverse do |node|
                next unless node.element?

                node.attribute_nodes.each do |attribute|
                  raise Error.new(:malformed_response) if dangerous_attribute?(attribute)
                end
              end
            end
          end
        end

        def dangerous_attribute?(attribute)
          name = attribute.name.to_s.downcase
          prefix = attribute.namespace&.prefix.to_s.downcase
          qualified = prefix.empty? ? name : "#{prefix}:#{name}"
          return true if name.start_with?("on")
          return true if DANGEROUS_ATTRIBUTES.include?(name) || DANGEROUS_ATTRIBUTES.include?(qualified)

          dangerous_scheme?(attribute.value)
        end

        def dangerous_scheme?(value)
          return false unless value.is_a?(String) && value.include?(":")

          candidate = value.gsub(SCHEME_NOISE, "").lstrip.downcase
          DANGEROUS_SCHEMES.any? { |scheme| candidate.start_with?("#{scheme}:") }
        end

        def object!(value, allowed)
          raise Error.new(:malformed_response) unless value.is_a?(Hash)

          allowed_keys!(value, allowed)
        end

        def allowed_keys!(value, allowed)
          raise Error.new(:malformed_response) unless (value.keys - allowed).empty?
        end

        def exact_keys!(value, expected)
          raise Error.new(:invalid_input) unless value.keys.sort == expected
        end

        def identifier!(value)
          unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
              value.bytesize.between?(1, 200) && value.match?(IDENTIFIER)
            raise Error.new(:invalid_input)
          end
        end

        # Outgoing single-line list filters, mirroring the bound the adapter
        # applies before the call is made.
        def filter_text!(value)
          unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
              value.bytesize.between?(1, MAX_FILTER_BYTES) && !value.match?(CONTROL_CHARACTERS)
            raise Error.new(:invalid_input)
          end
        end

        def country!(value)
          unless value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding? &&
              value.bytesize == 2 && value.match?(COUNTRY)
            raise Error.new(:invalid_input)
          end
        end

        def canonicalize(value)
          case value
          when Hash
            value.keys.sort.each_with_object({}) do |key, result|
              result[key.dup.freeze] = canonicalize(value.fetch(key))
            end.freeze
          when Array
            value.map { |child| canonicalize(child) }.freeze
          when String
            value.dup.freeze
          else
            value
          end
        end

        def encode_json(value)
          case value
          when Hash
            "{#{value.map { |key, child| "#{JSON.generate(key)}:#{encode_json(child)}" }.join(",")}}"
          when Array
            "[#{value.map { |child| encode_json(child) }.join(",")}]"
          when String
            JSON.generate(value)
          when Integer
            value.to_s
          when BigDecimal
            value.to_s("F")
          when TrueClass
            "true"
          when FalseClass
            "false"
          when NilClass
            "null"
          else
            raise Error.new(:malformed_response)
          end
        end
    end
  end
end
