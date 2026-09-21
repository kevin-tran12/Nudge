require "test_helper"

class ProdigiErrorTest < ActiveSupport::TestCase
  CODES = %i[
    invalid_input unsupported_mode fixture_miss missing_credentials malformed_response
    unsafe_url authentication_failed throttled unavailable provider_rejected
    validation_failed not_found conflict
  ].freeze

  test "CODES is the fixed, frozen list this phase specifies -- nothing more, nothing less" do
    assert_equal CODES.sort, Integrations::Prodigi::Error::CODES.sort
    assert Integrations::Prodigi::Error::CODES.frozen?
  end

  test "STRATEGIES maps only throttled and unavailable to backoff, everything else to never" do
    strategies = Integrations::Prodigi::Error::STRATEGIES
    assert strategies.frozen?
    assert_equal Integrations::Prodigi::Error::CODES.sort, strategies.keys.sort

    backoff_codes = strategies.select { |_, strategy| strategy == :backoff }.keys
    assert_equal %i[throttled unavailable].sort, backoff_codes.sort

    (Integrations::Prodigi::Error::CODES - %i[throttled unavailable]).each do |code|
      assert_equal :never, strategies.fetch(code), "#{code} must not be retried automatically"
    end
  end

  test "retryable? is true only for backoff-classified codes" do
    assert Integrations::Prodigi::Error.new(:throttled).retryable?
    assert Integrations::Prodigi::Error.new(:unavailable).retryable?
    refute Integrations::Prodigi::Error.new(:invalid_input).retryable?
    refute Integrations::Prodigi::Error.new(:not_found).retryable?
  end

  test "an unknown code is rejected rather than silently accepted" do
    [ :made_up_code, "throttled", nil, 1, :Throttled ].each do |bad_code|
      assert_raises(ArgumentError) { Integrations::Prodigi::Error.new(bad_code) }
    end
  end

  test "the message never echoes raw provider text -- only the fixed code" do
    error = Integrations::Prodigi::Error.new(:provider_rejected)
    assert_equal "Prodigi adapter: provider_rejected", error.message
    assert_equal "Prodigi adapter: provider_rejected", error.to_s
  end

  test "inspect, to_s, as_json, and to_json only ever expose the code" do
    error = Integrations::Prodigi::Error.new(:authentication_failed)

    assert_equal "#<Integrations::Prodigi::Error code=:authentication_failed>", error.inspect
    assert_equal({ "code" => "authentication_failed" }, error.as_json)
    assert_equal JSON.generate("code" => "authentication_failed"), error.to_json
    refute_match(/secret|token|api[_-]?key/i, error.inspect)
  end

  test "code is exposed but frozen against mutation via a fresh instance" do
    error = Integrations::Prodigi::Error.new(:conflict)
    assert_equal :conflict, error.code
    assert error.code.frozen? # symbols are always frozen -- guards against a future string code
  end
end
