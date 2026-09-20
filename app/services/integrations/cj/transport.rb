require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module Integrations
  module Cj
    # Real CJ HTTP transport using only the Ruby standard library. Only reachable
    # from Integrations::Cj::Adapter in a non-fixture mode, which itself is only
    # reachable through an explicit ModePolicy capability sentinel from trusted
    # server code (see ModePolicy). This class never chooses a mode and never
    # decides whether to call CJ; it only knows how to make one bounded, safe
    # HTTP request when told to.
    #
    # Endpoint host/paths mirror the publicly documented CJ API v2 surface
    # (.planning/CJ_SCHEMA_EVIDENCE.md) and the operation paths already used by
    # Normalizer::ENDPOINTS. The exact wire shape of the authentication response
    # is unconfirmed until an owner-authorized bounded verify/record run
    # captures it; this transport fails closed (:malformed_response) on any
    # unexpected shape rather than guessing permissively.
    #
    # Safety properties held on every call:
    # - bounded open/read timeouts;
    # - bounded response size, enforced while streaming (never buffers an
    #   unbounded body in memory);
    # - TLS certificate verification on (VERIFY_PEER);
    # - redirects are never followed -- a 3xx response is treated as an
    #   ordinary unexpected status (:provider_rejected), and the Location
    #   header is never read or acted on.
    class Transport
      HOST = "developers.cjdropshipping.com"
      BASE_PATH = "/api2.0/v1"
      AUTH_PATH = "#{BASE_PATH}/authentication/getAccessToken"
      OPEN_TIMEOUT = 3
      READ_TIMEOUT = 8
      MAX_RESPONSE_BYTES = 1_048_576
      MAX_CREDENTIAL_BYTES = 4_096
      MAX_TOKEN_BYTES = 8_192

      # http_start is an injectable seam over Net::HTTP.start so tests can
      # exercise real request-building/response-classification logic without
      # ever opening a socket. It defaults to the real standard-library call.
      def initialize(http_start: Net::HTTP.method(:start))
        @http_start = http_start
      end

      # Exchanges the long-lived CJ credential for a short-lived access token.
      # Returns the plain hash shape Integrations::Cj::Authentication expects:
      # { value:, expires_at: }. Never logs, inspects, or serializes the
      # credential or the returned token.
      def authenticate(credential:)
        unless credential.is_a?(String) && credential.encoding == Encoding::UTF_8 &&
            credential.valid_encoding? && credential.bytesize.between?(1, MAX_CREDENTIAL_BYTES)
          raise Error.new(:invalid_input), cause: nil
        end

        body = post(AUTH_PATH, headers: { "Content-Type" => "application/json" },
          body: JSON.generate("apiKey" => credential))
        payload = parse_envelope(body)
        data = payload["data"]
        raise Error.new(:malformed_response), cause: nil unless data.is_a?(Hash)

        token = data["accessToken"]
        expiry = data["accessTokenExpiryDate"]
        unless token.is_a?(String) && token.encoding == Encoding::UTF_8 && token.valid_encoding? &&
            token.bytesize.between?(1, MAX_TOKEN_BYTES)
          raise Error.new(:malformed_response), cause: nil
        end

        { value: token, expires_at: parse_expiry(expiry) }
      rescue JSON::ParserError
        raise Error.new(:malformed_response), cause: nil
      end

      # Performs one bounded CJ data call for the given normalized operation and
      # returns the raw JSON response body as a string. Business-level CJ error
      # codes embedded in a 200 OK envelope (e.g. quota/auth codes) are left for
      # Integrations::Cj::Normalizer to interpret; this method only classifies
      # HTTP transport-level outcomes.
      # CJ's query/list endpoints (product/list) are GET with query parameters;
      # the write-shaped lookups (product/query, stock, freight) are POST with a
      # JSON body. This set is the wire contract, not a normalization choice.
      GET_OPERATIONS = %i[product_list].freeze

      def call(operation:, token:, request:)
        path = "#{BASE_PATH}/#{Normalizer::ENDPOINTS.fetch(operation)}"
        unless token.is_a?(String) && token.encoding == Encoding::UTF_8 && token.valid_encoding? &&
            token.bytesize.between?(1, MAX_TOKEN_BYTES)
          raise Error.new(:invalid_input), cause: nil
        end

        headers = { "CJ-Access-Token" => token }
        if GET_OPERATIONS.include?(operation)
          get(path, headers: headers, query: request)
        else
          post(path, headers: headers.merge("Content-Type" => "application/json"), body: JSON.generate(request))
        end
      end

      private

      def post(path, headers:, body:)
        uri = URI::HTTPS.build(host: HOST, path: path)
        request = Net::HTTP::Post.new(uri)
        headers.each { |key, value| request[key] = value }
        request.body = body

        perform(uri, request)
      end

      # request must be a flat Hash of string/symbol keys to primitive values;
      # nil-valued keys are omitted rather than serialized as an empty param,
      # since CJ's query endpoints treat an empty filter value as present.
      def get(path, headers:, query:)
        raise Error.new(:invalid_input), cause: nil unless query.is_a?(Hash)

        pairs = query.reject { |_, value| value.nil? }.map { |key, value| [ key.to_s, value.to_s ] }
        uri = URI::HTTPS.build(host: HOST, path: path, query: URI.encode_www_form(pairs))
        request = Net::HTTP::Get.new(uri)
        headers.each { |key, value| request[key] = value }

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

      # Streams the body with a hard byte cap instead of buffering an unbounded
      # response, then maps the HTTP status to a transport-level outcome. A
      # redirect (3xx) is intentionally never followed and falls into the
      # generic :provider_rejected branch below.
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
        when Net::HTTPServerError
          raise Error.new(:unavailable), cause: nil
        else
          raise Error.new(:provider_rejected), cause: nil
        end
      end

      def parse_envelope(body)
        payload = JSON.parse(body)
        raise Error.new(:malformed_response), cause: nil unless payload.is_a?(Hash)

        payload
      end

      def parse_expiry(value)
        case value
        when String
          Time.iso8601(value)
        else
          raise Error.new(:malformed_response), cause: nil
        end
      rescue ArgumentError
        begin
          Time.strptime(value, "%Y-%m-%d %H:%M:%S").utc
        rescue ArgumentError, TypeError
          raise Error.new(:malformed_response), cause: nil
        end
      end
    end
  end
end
