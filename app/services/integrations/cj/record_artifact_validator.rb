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
      OPERATIONS = %i[product inventory freight].freeze
      IDENTIFIER = /\A[A-Za-z0-9_{}-]+\z/
      COUNTRY = /\A[A-Z]{2}\z/
      FORBIDDEN_KEYS = %w[
        accesstoken refreshtoken openid authorization sign signature apikey
        email phone recipientname customername address address1 address2 zip
        zipcode postalcode token credential secret password
      ].freeze
      RESPONSE_KEYS = %w[code data message requestId result].freeze
      PRODUCT_KEYS = %w[description pid productImageSet productNameEn productSku variants].freeze
      VARIANT_KEYS = %w[
        pid variantHeight variantLength variantNameEn variantSellPrice variantSku
        variantWeight variantWidth vid
      ].freeze
      INVENTORY_KEYS = %w[
        areaId cjInventoryNum countryCode factoryInventoryNum stock totalInventoryNum vid
      ].freeze
      STOCK_KEYS = %w[factoryInventory inventory stockId].freeze
      FREIGHT_KEYS = %w[
        clearanceOperationFee logisticAging logisticName logisticPrice taxesFee totalPostageFee
      ].freeze
      ACTIVE_ELEMENTS = "script, style, template, iframe, object".freeze
      MAX_ABSOLUTE_NUMBER = BigDecimal("9999999999").freeze
      MIN_DECIMAL_EXPONENT = -24

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

                raise Error.new(:malformed_response) if node.attribute_nodes.any?
              end
            end
          end
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
