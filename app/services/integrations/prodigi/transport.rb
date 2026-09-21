require "json"
require "net/http"
require "openssl"
require "uri"

module Integrations
  module Prodigi
    # Real Prodigi HTTP transport using only the Ruby standard library. Only
    # reachable from Integrations::Prodigi::Adapter in :sandbox mode, which
    # itself is only reachable through an explicit ModePolicy capability
    # sentinel from trusted server code (see ModePolicy). This class never
    # chooses a mode and never decides whether to call Prodigi; it only knows
    # how to make one bounded, safe HTTP request when told to.
    #
    # HOSTS deliberately has no :live entry -- see
    # ModePolicy::SANDBOX_CAPABILITY for why. Endpoint paths mirror the publicly
    # documented Prodigi API v4 surface passed down for this phase; the exact
    # wire shape of a response is unconfirmed until an owner-authorized
    # sandbox capture (lib/tasks/prodigi.rake) records one, so this transport
    # fails closed (:malformed_response) on any unexpected shape rather than
    # guessing permissively.
    #
    # Safety properties held on every call:
    # - bounded open/read timeouts;
    # - bounded response size, enforced while streaming (never buffers an
    #   unbounded body in memory);
    # - TLS certificate verification on (VERIFY_PEER);
    # - redirects are never followed -- a 3xx response is treated as an
    #   ordinary unexpected status (:malformed_response), and the Location
    #   header is never read or acted on.
    class Transport
      HOSTS = { sandbox: "api.sandbox.prodigi.com" }.freeze
      BASE_PATH = "/v4.0"
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 8
      MAX_RESPONSE_BYTES = 1_048_576
      MAX_KEY_BYTES = 4_096

      # http_start is an injectable seam over Net::HTTP.start so tests can
      # exercise real request-building/response-classification logic without
      # ever opening a socket. It defaults to the real standard-library call.
      def initialize(http_start: Net::HTTP.method(:start))
        @http_start = http_start
      end

      # Prodigi has no rate-limit documentation and no points-quota system
      # like CJ's, so admission (Pacer) happens one layer up in Adapter, not
      # here -- this class only knows how to make one HTTP call, never how
      # many are safe to make.
      def call(operation:, api_key:, request:)
        unless api_key.is_a?(String) && api_key.bytesize.between?(1, MAX_KEY_BYTES)
          raise Error.new(:invalid_input), cause: nil
        end
        raise Error.new(:invalid_input), cause: nil unless request.is_a?(Hash)

        headers = { "X-API-Key" => api_key }
        case operation
        when :product
          get("#{BASE_PATH}/products/#{path_segment(request, "sku")}", headers: headers)
        when :quote
          post("#{BASE_PATH}/quotes", headers: headers, body: request)
        when :create_order
          post("#{BASE_PATH}/orders", headers: headers, body: request)
        when :order_status
          get("#{BASE_PATH}/orders/#{path_segment(request, "order_id")}", headers: headers)
        else
          raise Error.new(:invalid_input), cause: nil
        end
      end

      private

      def path_segment(request, key)
        value = request[key]
        unless value.is_a?(String) && value.bytesize.between?(1, 200)
          raise Error.new(:invalid_input), cause: nil
        end

        value
      end

      def get(path, headers:)
        uri = URI::HTTPS.build(host: HOSTS.fetch(:sandbox), path: path)
        request = Net::HTTP::Get.new(uri)
        headers.each { |key, value| request[key] = value }

        perform(uri, request)
      end

      def post(path, headers:, body:)
        uri = URI::HTTPS.build(host: HOSTS.fetch(:sandbox), path: path)
        request = Net::HTTP::Post.new(uri)
        headers.each { |key, value| request[key] = value }
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        perform(uri, request)
      end

      def perform(uri, request)
        @http_start.call(uri.host, uri.port, use_ssl: true,
          verify_mode: OpenSSL::SSL::VERIFY_PEER, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.request(request) { |http_response| return classify(http_response) }
        end
        raise Error.new(:unavailable), cause: nil
      rescue Error
        raise
      rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, IOError, SocketError, SystemCallError, OpenSSL::SSL::SSLError
        raise Error.new(:unavailable), cause: nil
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end

      # Streams the body with a hard byte cap instead of buffering an
      # unbounded response, then maps the HTTP status to the documented
      # Prodigi error taxonomy. A redirect (3xx) is intentionally never
      # followed and falls into the generic :malformed_response branch below.
      def classify(response)
        buffer = +""
        response.read_body do |chunk|
          buffer << chunk
          raise Error.new(:malformed_response), cause: nil if buffer.bytesize > MAX_RESPONSE_BYTES
        end

        case response
        when Net::HTTPSuccess
          raise Error.new(:malformed_response), cause: nil if buffer.empty?
          buffer
        when Net::HTTPUnauthorized, Net::HTTPForbidden
          raise Error.new(:authentication_failed), cause: nil
        when Net::HTTPTooManyRequests
          raise Error.new(:throttled), cause: nil
        when Net::HTTPNotFound
          raise Error.new(:not_found), cause: nil
        when Net::HTTPBadRequest
          raise Error.new(:validation_failed), cause: nil
        when Net::HTTPServerError
          raise Error.new(:unavailable), cause: nil
        else
          raise Error.new(:malformed_response), cause: nil
        end
      end
    end
  end
end
