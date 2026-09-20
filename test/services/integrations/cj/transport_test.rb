require "test_helper"

class CjTransportTest < ActiveSupport::TestCase
  test "authenticate parses a well-formed access token response" do
    body = JSON.generate("data" => { "accessToken" => "synthetic-access-token",
      "accessTokenExpiryDate" => "2026-10-01T00:00:00Z" })
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: body))

    result = transport.authenticate(credential: "synthetic-credential")

    assert_equal "synthetic-access-token", result[:value]
    assert_equal Time.iso8601("2026-10-01T00:00:00Z"), result[:expires_at]
  end

  test "authenticate accepts the alternate documented date-time expiry format" do
    body = JSON.generate("data" => { "accessToken" => "tok", "accessTokenExpiryDate" => "2026-10-01 00:00:00" })
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: body))

    result = transport.authenticate(credential: "synthetic-credential")

    assert_equal Time.utc(2026, 10, 1), result[:expires_at]
  end

  test "authenticate rejects an invalid credential without ever building a request" do
    transport = build_transport(nil) { flunk "invalid credential reached the network seam" }

    [ nil, "", 1234, "x" * 4_097, "bad\xFF".dup.force_encoding("UTF-8") ].each do |credential|
      assert_cj_error(:invalid_input) { transport.authenticate(credential: credential) }
    end
  end

  test "authenticate fails closed on a malformed token envelope" do
    [ "not json", "[]", JSON.generate("data" => nil), JSON.generate("data" => {}),
      JSON.generate("data" => { "accessToken" => "", "accessTokenExpiryDate" => "2026-10-01T00:00:00Z" }),
      JSON.generate("data" => { "accessToken" => "tok", "accessTokenExpiryDate" => "not-a-time" }),
      JSON.generate("data" => { "accessToken" => "tok", "accessTokenExpiryDate" => nil }) ].each do |body|
      transport = build_transport(fake_response(Net::HTTPOK, "200", body: body))
      assert_cj_error(:malformed_response) { transport.authenticate(credential: "synthetic-credential") }
    end
  end

  test "call sends the bearer token and returns the raw success body untouched" do
    seen_request = nil
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: '{"code":200,"result":true}')) do |request|
      seen_request = request
    end

    body = transport.call(operation: :product, token: "synthetic-token", request: { "product_id" => "1" })

    assert_equal '{"code":200,"result":true}', body
    assert_equal "synthetic-token", seen_request["CJ-Access-Token"]
    # Verified against the live provider: product/query is a GET keyed on pid,
    # so the domain key product_id is translated at the wire boundary.
    assert_equal "/api2.0/v1/product/query?pid=1", seen_request.path
    assert_kind_of Net::HTTP::Get, seen_request
  end

  test "call rejects an invalid token without building a request" do
    transport = build_transport(nil) { flunk "invalid token reached the network seam" }
    assert_cj_error(:invalid_input) { transport.call(operation: :product, token: "", request: {}) }
  end

  test "HTTP status codes classify into the shared CJ error taxonomy" do
    { Net::HTTPUnauthorized => [ "401", :authentication_failed ], Net::HTTPForbidden => [ "403", :authentication_failed ],
      Net::HTTPTooManyRequests => [ "429", :throttled ], Net::HTTPInternalServerError => [ "500", :unavailable ],
      Net::HTTPBadGateway => [ "502", :unavailable ], Net::HTTPMovedPermanently => [ "301", :provider_rejected ],
      Net::HTTPBadRequest => [ "400", :provider_rejected ] }.each do |klass, (code, expected)|
      transport = build_transport(fake_response(klass, code, body: "irrelevant"))
      error = assert_cj_error(expected) { transport.call(operation: :product, token: "t", request: {}) }
      assert_equal Integrations::Cj::Error::STRATEGIES.fetch(expected), error.retry_strategy
    end
  end

  test "an empty success body is malformed rather than a silent empty result" do
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: ""))
    assert_cj_error(:malformed_response) { transport.call(operation: :product, token: "t", request: {}) }
  end

  test "a response streamed past the byte cap is rejected before it is fully buffered" do
    chunks = Array.new(20) { "x" * 100_000 }
    transport = build_transport(fake_response(Net::HTTPOK, "200", chunks: chunks))
    assert_cj_error(:malformed_response) { transport.call(operation: :product, token: "t", request: {}) }
  end

  test "connection failures classify as unavailable rather than raw exceptions" do
    [ Net::OpenTimeout.new, Net::ReadTimeout.new, SocketError.new, Errno::ECONNRESET.new,
      OpenSSL::SSL::SSLError.new ].each do |raised|
      transport = Integrations::Cj::Transport.new(http_start: ->(*_args, **_kwargs) { raise raised })
      error = assert_cj_error(:unavailable) { transport.call(operation: :product, token: "t", request: {}) }
      assert_nil error.cause
    end
  end

  test "credentials and tokens never appear in a raised error's message" do
    transport = Integrations::Cj::Transport.new(http_start: ->(*_args, **_kwargs) { raise "synthetic-secret-token" })
    error = assert_raises(Integrations::Cj::Error) { transport.call(operation: :product, token: "t", request: {}) }
    refute_includes error.message, "synthetic-secret-token"
    assert_nil error.cause
  end

  private
    def fake_response(klass, code, body: nil, chunks: nil)
      response = klass.new("1.1", code, "test")
      payload = chunks || [ body ]
      response.define_singleton_method(:read_body) { |&block| payload.each { |chunk| block.call(chunk) } }
      response
    end

    # Builds a Transport whose Net::HTTP.start seam is replaced by a fake that
    # never opens a socket: it exposes a #request method matching Net::HTTP's,
    # optionally records the built request, and immediately yields the given
    # canned response.
    def build_transport(response, &on_request)
      Integrations::Cj::Transport.new(http_start: lambda do |*_args, **_kwargs, &blk|
        fake_http = Object.new
        fake_http.define_singleton_method(:request) do |request, &block|
          on_request&.call(request)
          block.call(response)
        end
        blk.call(fake_http)
      end)
    end

    def assert_cj_error(code, &block)
      error = assert_raises(Integrations::Cj::Error, &block)
      assert_equal code, error.code
      error
    end
end
