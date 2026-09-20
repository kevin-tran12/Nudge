require "test_helper"

# Verified against the live provider: product/query and product/stock/queryByVid
# are GET endpoints keyed on pid and vid. The adapter names its request keys for
# the domain, so the transport translates them at the wire boundary.
class CjTransportWireParametersTest < ActiveSupport::TestCase
  test "product and inventory are GET operations alongside the list" do
    assert_includes Integrations::Cj::Transport::GET_OPERATIONS, :product
    assert_includes Integrations::Cj::Transport::GET_OPERATIONS, :inventory
    assert_includes Integrations::Cj::Transport::GET_OPERATIONS, :product_list
  end

  test "freight is still a POST" do
    refute_includes Integrations::Cj::Transport::GET_OPERATIONS, :freight
  end

  test "the domain key for a product becomes CJ's pid" do
    assert_equal({ "product_id" => "pid" }, Integrations::Cj::Transport::WIRE_PARAMETERS.fetch(:product))
  end

  test "the domain key for inventory becomes CJ's vid" do
    assert_equal({ "variant_id" => "vid" }, Integrations::Cj::Transport::WIRE_PARAMETERS.fetch(:inventory))
  end

  test "the list already uses CJ spellings and needs no translation" do
    assert_nil Integrations::Cj::Transport::WIRE_PARAMETERS[:product_list]
  end

  test "a product request is sent as GET with pid and no body" do
    captured = capture_request(operation: :product, request: { "product_id" => "2609171015371625000" })

    assert_kind_of Net::HTTP::Get, captured
    assert_includes captured.uri.query, "pid=2609171015371625000"
    refute_includes captured.uri.query.to_s, "product_id"
    assert_nil captured.body
  end

  test "an inventory request is sent as GET with vid" do
    captured = capture_request(operation: :inventory, request: { "variant_id" => "2609161110071618400" })

    assert_kind_of Net::HTTP::Get, captured
    assert_includes captured.uri.query, "vid=2609161110071618400"
    refute_includes captured.uri.query.to_s, "variant_id"
  end

  test "list parameters pass through unchanged" do
    captured = capture_request(operation: :product_list,
      request: { "pageNum" => 1, "pageSize" => 2, "categoryId" => "abc", "keyword" => nil })

    assert_includes captured.uri.query, "pageNum=1"
    assert_includes captured.uri.query, "categoryId=abc"
    refute_includes captured.uri.query, "keyword"
  end

  private

  # Uses the transport's own injected http_start seam, so nothing leaves the
  # process and no socket is opened.
  def capture_request(operation:, request:)
    captured = nil
    http = Object.new
    http.define_singleton_method(:request) do |req, &blk|
      captured = req
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      body = '{"code":200,"result":true,"message":"ok","data":{},"requestId":"r"}'
      response.instance_variable_set(:@body, body)
      response.define_singleton_method(:body) { body }
      # classify streams the body rather than buffering it.
      response.define_singleton_method(:read_body) { |&chunk| chunk ? chunk.call(body) : body }
      blk ? blk.call(response) : response
    end

    transport = Integrations::Cj::Transport.new(
      http_start: ->(*_args, **_kwargs, &blk) { blk.call(http) }
    )
    transport.call(operation: operation, token: "token-value", request: request)
    captured
  end
end
