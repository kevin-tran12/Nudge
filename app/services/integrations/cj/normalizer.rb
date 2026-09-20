require "bigdecimal"
require "digest"
require "json"
require "time"
require "uri"

module Integrations
  module Cj
    class Normalizer
      MAX_BODY_BYTES = 262_144
      MAX_LIST_ITEMS = 200
      # oss-cf.cjdropshipping.com verified against live CJ product detail responses.
      MEDIA_HOSTS = %w[cf.cjdropshipping.com oss-cf.cjdropshipping.com
        cc-west-usa.oss-us-west-1.aliyuncs.com].freeze
      ENDPOINTS = { product: "product/query", inventory: "product/stock/queryByVid", freight: "logistic/freightCalculate",
        product_list: "product/list" }.freeze

      def call(operation:, body:, request:, observed_at:)
        invalid! unless ENDPOINTS.key?(operation) && body.is_a?(String) && body.bytesize <= MAX_BODY_BYTES
        payload = JSON.parse(body, decimal_class: BigDecimal, max_nesting: 12)
        invalid! unless payload.is_a?(Hash) && payload["code"].is_a?(Integer) && [ true, false ].include?(payload["result"])
        raise Error.new(error_code(payload["code"])) unless payload["code"] == 200
        invalid! unless payload["result"] == true

        value = case operation
        when :product then product(payload["data"], request.fetch("product_id"))
        when :inventory then inventory(payload["data"], request.fetch("variant_id"))
        when :freight then freight(payload["data"])
        when :product_list then product_list(payload["data"], request)
        end
        provenance = Contracts::Provenance.new(provider: :cj, source: :synthetic_fixture,
          endpoint_key: ENDPOINTS.fetch(operation), adapter_version: "1", payload_version: "1",
          payload_sha256: Digest::SHA256.hexdigest(body), observed_at: Time.iso8601(observed_at),
          request_id: optional_text(payload["requestId"], limit: 48))
        Contracts.deep_freeze(Contracts::Result.new(value: value, provenance: provenance, request: request.deep_dup))
      rescue JSON::ParserError, ArgumentError, KeyError, TypeError
        raise Error.new(:malformed_response), cause: nil
      end

      private
        def product(data, expected_id)
          object!(data)
          id = identifier(data["pid"])
          invalid! unless id == expected_id
          variants = array!(data["variants"], limit: 200).map { |row| variant(row, id) }
          invalid! unless variants.map(&:external_id).uniq.size == variants.size

          Contracts::Product.new(external_id: id, sku: optional_reference(data["productSku"]),
            title: plain_text(data["productNameEn"], limit: 200),
            description: data["description"].nil? ? nil : plain_text(data["description"], limit: 16_384),
            image_urls: data["productImageSet"].nil? ? nil : array!(data["productImageSet"], limit: 50).map { |url| media_url(url) },
            variants: variants)
        end

        def variant(row, product_id)
          object!(row)
          invalid! unless identifier(row["pid"]) == product_id
          Contracts::Variant.new(external_id: identifier(row["vid"]), product_id: product_id,
            sku: optional_reference(row["variantSku"]), title: optional_text(row["variantNameEn"]),
            price: money(row["variantSellPrice"]), weight: measurement(row["variantWeight"], "g"),
            length: measurement(row["variantLength"], "mm"), width: measurement(row["variantWidth"], "mm"),
            height: measurement(row["variantHeight"], "mm"))
        end

        def inventory(data, variant_id)
          rows = array!(data, limit: 100).map do |row|
            object!(row)
            invalid! unless identifier(row["vid"]) == variant_id
            country = text(row["countryCode"], limit: 2)
            invalid! unless country.match?(/\A[A-Z]{2}\z/)
            stocks = if row["stock"].nil?
              nil
            else
              array!(row["stock"], limit: 100).map do |stock|
                object!(stock)
                Contracts::Subwarehouse.new(external_id: identifier(stock["stockId"]),
                  cj_quantity: quantity(stock["inventory"]), factory_quantity: quantity(stock["factoryInventory"]))
              end
            end
            invalid! if stocks && stocks.map(&:external_id).uniq.size != stocks.size
            area_id = row["areaId"]
            area_id = area_id.to_s if area_id.is_a?(Integer) && area_id >= 0
            Contracts::Inventory.new(variant_id: variant_id.dup, warehouse_id: identifier(area_id),
              country_code: country, total_quantity: quantity(row["totalInventoryNum"]),
              cj_quantity: quantity(row["cjInventoryNum"]), factory_quantity: quantity(row["factoryInventoryNum"]),
              subwarehouses: stocks)
          end
          invalid! unless rows.map(&:warehouse_id).uniq.size == rows.size
          rows
        end

        def freight(data)
          array!(data, limit: 100).map do |row|
            object!(row)
            Contracts::Freight.new(service_name: plain_text(row["logisticName"], limit: 200),
              price: money(row["logisticPrice"]), tax: money(row["taxesFee"]),
              clearance_fee: money(row["clearanceOperationFee"]), total_price: money(row["totalPostageFee"]),
              delivery_estimate: optional_text(row["logisticAging"]),
              kind: :estimate, eligibility: :unknown, expires_at: nil)
          end
        end

        # Product List V2. Wire field names for the list envelope ("list",
        # "total") and per-item fields (pid/productNameEn/productSku/
        # productImage/sellPrice, inferred by analogy with the confirmed
        # product/variant field names in .planning/CJ_SCHEMA_EVIDENCE.md) are
        # not yet verified by an owner-authorized capture; an unexpected shape
        # fails closed rather than being guessed permissively. Page and page
        # size are taken from the already-validated outgoing request rather
        # than trusted from the response.
        def product_list(data, request)
          object!(data)
          page = request.fetch("pageNum")
          page_size = request.fetch("pageSize")
          total = total_count(data["total"])
          items = array!(data["list"], limit: MAX_LIST_ITEMS).map { |row| product_summary(row) }
          invalid! unless items.map(&:external_id).uniq.size == items.size

          Contracts::ProductListPage.new(products: items, page: page, page_size: page_size,
            total_count: total, has_more: (page * page_size) < total)
        end

        def product_summary(row)
          object!(row)
          Contracts::ProductSummary.new(external_id: identifier(row["pid"]),
            sku: optional_reference(row["productSku"]), title: plain_text(row["productNameEn"], limit: 200),
            image_url: row["productImage"].nil? ? nil : media_url(row["productImage"]),
            price: money(row["sellPrice"]))
        end

        def total_count(value)
          invalid! unless value.is_a?(Integer) && value.between?(0, 2_147_483_647)
          value
        end

        def money(value)
          return nil if value.nil?
          amount = decimal(value) * 100
          invalid! unless amount.frac.zero?
          Contracts::Money.new(amount_minor: amount.to_i, currency: "USD")
        end

        def measurement(value, unit)
          return nil if value.nil?
          Contracts::Measurement.new(value: decimal(value), unit: unit)
        end

        def decimal(value)
          invalid! unless value.is_a?(Integer) || value.is_a?(BigDecimal) || value.is_a?(String)
          # Validate numeric JSON decimals without expanding a hostile exponent.
          number = if value.is_a?(BigDecimal)
            value
          else
            string = value.to_s
            invalid! unless string.bytesize <= 24 && string.match?(/\A\d+(?:\.\d+)?\z/)
            BigDecimal(string)
          end
          invalid! unless number.finite? && number.between?(0, 9_999_999_999)
          invalid! unless number.zero? || number.exponent >= -24
          number
        end

        def quantity(value)
          return nil if value.nil?
          invalid! unless value.is_a?(Integer) && value.between?(0, 2_147_483_647)
          value
        end

        def identifier(value)
          text(value, limit: 200).tap { |id| invalid! unless id.match?(/\A[A-Za-z0-9_{}-]+\z/) }
        end

        def optional_text(value, limit: 200)
          value.nil? ? nil : plain_text(value, limit: limit)
        end

        def optional_reference(value)
          value.nil? ? nil : String.new(text(value, limit: 200))
        end

        def plain_text(value, limit:)
          fragment = Loofah.html5_fragment(text(value, limit: limit))
          fragment.css("script, style, template, iframe, object").remove
          String.new(fragment.text)
        end

        def text(value, limit:)
          invalid! unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, limit) && !value.match?(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/)
          value
        end

        def media_url(value)
          raise Error.new(:unsafe_url) unless value.is_a?(String) && value.bytesize.between?(1, 2048)
          uri = URI.parse(value)
          unless uri.is_a?(URI::HTTPS) && MEDIA_HOSTS.include?(uri.host) && uri.port == 443 &&
              uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? &&
              uri.path.match?(/\A\/[A-Za-z0-9_\/.\-]+\z/) && !uri.path.split("/").include?("..")
            raise Error.new(:unsafe_url)
          end
          value
        rescue URI::InvalidURIError
          raise Error.new(:unsafe_url), cause: nil
        end

        def array!(value, limit:)
          invalid! unless value.is_a?(Array) && value.size <= limit
          value
        end

        def object!(value)
          invalid! unless value.is_a?(Hash)
        end

        def invalid!
          raise Error.new(:malformed_response)
        end

        def error_code(code)
          case code
          when 1600001..1600009, 1600030, 1600031 then :authentication_failed
          when 1600200 then :throttled
          when 1600201 then :quota_exhausted
          when 1600000, 1600301 then :unavailable
          when 1602000, 1602001 then :not_found
          else :provider_rejected
          end
        end
    end
  end
end
