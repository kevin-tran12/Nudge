require "test_helper"

class ProdigiTransportTest < ActiveSupport::TestCase
  test "the only reachable host is the documented sandbox host -- there is no live host" do
    assert_equal({ sandbox: "api.sandbox.prodigi.com" }, Integrations::Prodigi::Transport::HOSTS)
    assert Integrations::Prodigi::Transport::HOSTS.frozen?
    refute Integrations::Prodigi::Transport::HOSTS.key?(:live)
    refute_includes Integrations::Prodigi::Transport::HOSTS.values, "api.prodigi.com"
  end

  test "no committed file under this adapter directory ever spells the live host" do
    root = Rails.root.join("app/services/integrations/prodigi")
    next skip("adapter directory not built yet") unless root.exist?

    Dir[root.join("**/*.rb")].each do |path|
      refute_match(/api\.prodigi\.com/, File.read(path), "#{path} must never reference the live Prodigi host")
    end
  end

  test "product sends a GET to /v4.0/products/:sku with the X-API-Key header" do
    seen_request = nil
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: %({"outcome":"Ok"}))) { |request| seen_request = request }

    body = transport.call(operation: :product, api_key: "synthetic-api-key", request: { "sku" => "GLOBAL-CFPM-16X24" })

    assert_equal %({"outcome":"Ok"}), body
    assert_kind_of Net::HTTP::Get, seen_request
    assert_equal "/v4.0/products/GLOBAL-CFPM-16X24", seen_request.path
    assert_equal "synthetic-api-key", seen_request["X-API-Key"]
  end

  test "quote sends a POST to /v4.0/quotes with the request JSON-encoded as the body" do
    seen_request = nil
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: %({"outcome":"Created"}))) { |request| seen_request = request }

    request_hash = { "destination_country" => "US", "items" => [ { "sku" => "GLOBAL-CFPM-16X24", "copies" => 1 } ] }
    transport.call(operation: :quote, api_key: "k", request: request_hash)

    assert_kind_of Net::HTTP::Post, seen_request
    assert_equal "/v4.0/quotes", seen_request.path
    assert_equal "k", seen_request["X-API-Key"]
    assert_equal request_hash, JSON.parse(seen_request.body)
  end

  test "create_order sends a POST to /v4.0/orders with the request JSON-encoded as the body" do
    seen_request = nil
    transport = build_transport(fake_response(Net::HTTPOK, "201", body: %({"outcome":"Created"}))) { |request| seen_request = request }

    request_hash = { "merchant_reference" => "order-ref-1", "idempotency_key" => "idem-1" }
    transport.call(operation: :create_order, api_key: "k", request: request_hash)

    assert_kind_of Net::HTTP::Post, seen_request
    assert_equal "/v4.0/orders", seen_request.path
    assert_equal request_hash, JSON.parse(seen_request.body)
  end

  test "order_status sends a GET to /v4.0/orders/:id" do
    seen_request = nil
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: %({"outcome":"Ok"}))) { |request| seen_request = request }

    transport.call(operation: :order_status, api_key: "k", request: { "order_id" => "ord_fixture_1" })

    assert_kind_of Net::HTTP::Get, seen_request
    assert_equal "/v4.0/orders/ord_fixture_1", seen_request.path
  end

  test "an unknown operation is rejected without building a request" do
    transport = build_transport(nil) { flunk "unknown operation reached the network seam" }
    assert_prodigi_error(:invalid_input) { transport.call(operation: :nonexistent, api_key: "k", request: {}) }
  end

  test "HTTP status codes classify into the documented Prodigi error taxonomy" do
    {
      Net::HTTPUnauthorized => [ "401", :authentication_failed ],
      Net::HTTPForbidden => [ "403", :authentication_failed ],
      Net::HTTPTooManyRequests => [ "429", :throttled ],
      Net::HTTPInternalServerError => [ "500", :unavailable ],
      Net::HTTPBadGateway => [ "502", :unavailable ],
      Net::HTTPNotFound => [ "404", :not_found ],
      Net::HTTPBadRequest => [ "400", :validation_failed ],
      Net::HTTPMovedPermanently => [ "301", :malformed_response ]
    }.each do |klass, (code, expected)|
      transport = build_transport(fake_response(klass, code, body: "irrelevant"))
      error = assert_prodigi_error(expected) { transport.call(operation: :product, api_key: "k", request: { "sku" => "s" }) }
      assert_equal Integrations::Prodigi::Error::STRATEGIES.fetch(expected), error.retry_strategy
    end
  end

  test "throttled and unavailable are the only retryable classifications from this transport" do
    { "429" => Net::HTTPTooManyRequests, "500" => Net::HTTPInternalServerError }.each do |code, klass|
      transport = build_transport(fake_response(klass, code, body: "irrelevant"))
      error = assert_raises(Integrations::Prodigi::Error) { transport.call(operation: :product, api_key: "k", request: { "sku" => "s" }) }
      assert error.retryable?
    end
  end

  test "an empty success body is malformed rather than a silent empty result" do
    transport = build_transport(fake_response(Net::HTTPOK, "200", body: ""))
    assert_prodigi_error(:malformed_response) { transport.call(operation: :product, api_key: "k", request: { "sku" => "s" }) }
  end

  test "a response streamed past the byte cap is rejected before it is fully buffered" do
    chunks = Array.new(20) { "x" * 100_000 }
    transport = build_transport(fake_response(Net::HTTPOK, "200", chunks: chunks))
    assert_prodigi_error(:malformed_response) { transport.call(operation: :product, api_key: "k", request: { "sku" => "s" }) }
    assert_equal 1_048_576, Integrations::Prodigi::Transport::MAX_RESPONSE_BYTES
  end

  test "connection failures classify as unavailable rather than raw exceptions, and never carry a cause" do
    [ Net::OpenTimeout.new, Net::ReadTimeout.new, SocketError.new, Errno::ECONNRESET.new,
      OpenSSL::SSL::SSLError.new ].each do |raised|
      transport = Integrations::Prodigi::Transport.new(http_start: ->(*_args, **_kwargs) { raise raised })
      error = assert_prodigi_error(:unavailable) { transport.call(operation: :product, api_key: "k", request: { "sku" => "s" }) }
      assert_nil error.cause
    end
  end

  test "the API key and any secret never appear in a raised error message" do
    transport = Integrations::Prodigi::Transport.new(http_start: ->(*_args, **_kwargs) { raise "synthetic-secret-api-key-leak" })
    error = assert_raises(Integrations::Prodigi::Error) { transport.call(operation: :product, api_key: "synthetic-secret-api-key-leak", request: { "sku" => "s" }) }
    refute_includes error.message, "synthetic-secret-api-key-leak"
  end

  test "every request verifies TLS peer identity, follows no redirects, and is bounded by timeouts" do
    seen_kwargs = nil
    transport = Integrations::Prodigi::Transport.new(http_start: lambda do |host, port, **kwargs, &blk|
      seen_kwargs = kwargs
      fake_http = Object.new
      fake_http.define_singleton_method(:request) { |_request, &block| block.call(fake_response(Net::HTTPOK, "200", body: "{}")) }
      blk.call(fake_http)
    end)

    transport.call(operation: :product, api_key: "k", request: { "sku" => "s" })

    assert_equal true, seen_kwargs[:use_ssl]
    assert_equal OpenSSL::SSL::VERIFY_PEER, seen_kwargs[:verify_mode]
    assert seen_kwargs.key?(:open_timeout)
    assert seen_kwargs.key?(:read_timeout)
  end

  private
    def fake_response(klass, code, body: nil, chunks: nil)
      response = klass.new("1.1", code, "test")
      payload = chunks || [ body ]
      response.define_singleton_method(:read_body) { |&block| payload.each { |chunk| block.call(chunk) } }
      response
    end

    def build_transport(response, &on_request)
      Integrations::Prodigi::Transport.new(http_start: lambda do |*_args, **_kwargs, &blk|
        fake_http = Object.new
        fake_http.define_singleton_method(:request) do |request, &block|
          on_request&.call(request)
          block.call(response)
        end
        blk.call(fake_http)
      end)
    end

    def assert_prodigi_error(code, &block)
      error = assert_raises(Integrations::Prodigi::Error, &block)
      assert_equal code, error.code
      error
    end
end
