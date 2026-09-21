require "test_helper"

# Prodigi documents no rate limit, so this adapter self-limits defensively
# rather than trusting the provider to tell it when to slow down. Fixture mode
# never touches this class: there is no real network to protect in fixture
# mode, so paying its cost there would be pure overhead.
class ProdigiPacerTest < ActiveSupport::TestCase
  test "MIN_INTERVAL and MAX_CALLS_PER_INSTANCE are the documented defensive bounds" do
    assert_equal 0.5, Integrations::Prodigi::Pacer::MIN_INTERVAL
    assert_equal 200, Integrations::Prodigi::Pacer::MAX_CALLS_PER_INSTANCE
  end

  test "a call within MIN_INTERVAL of the previous one is throttled with a positive retry_after" do
    clock = fake_clock(100.0)
    pacer = Integrations::Prodigi::Pacer.new(clock: clock)

    pacer.throttle!
    clock.value = 100.2 # 0.2s later, under the 0.5s minimum interval

    error = assert_raises(Integrations::Prodigi::Error) { pacer.throttle! }
    assert_equal :throttled, error.code
    assert_in_delta 0.3, error.retry_after, 0.001
  end

  test "a call at or after MIN_INTERVAL is allowed and resets the window" do
    clock = fake_clock(100.0)
    pacer = Integrations::Prodigi::Pacer.new(clock: clock)

    pacer.throttle!
    clock.value = 100.5
    assert_nothing_raised { pacer.throttle! }
    clock.value = 101.0
    assert_nothing_raised { pacer.throttle! }
  end

  test "MAX_CALLS_PER_INSTANCE is a hard sanity ceiling that raises throttled once reached" do
    clock = fake_clock(0.0)
    pacer = Integrations::Prodigi::Pacer.new(clock: clock)

    Integrations::Prodigi::Pacer::MAX_CALLS_PER_INSTANCE.times do
      clock.value += 1.0
      pacer.throttle!
    end

    clock.value += 1.0
    error = assert_raises(Integrations::Prodigi::Error) { pacer.throttle! }
    assert_equal :throttled, error.code
    refute_nil error.retry_after
  end

  test "throttled is the only code this pacer ever raises, and it is retryable" do
    clock = fake_clock(0.0)
    pacer = Integrations::Prodigi::Pacer.new(clock: clock)
    pacer.throttle!
    clock.value += 0.01

    error = assert_raises(Integrations::Prodigi::Error) { pacer.throttle! }
    assert_equal :throttled, error.code
    assert error.retryable?
  end

  test "fixture-mode adapter calls never invoke the pacer at all" do
    pacer = Object.new
    pacer.define_singleton_method(:throttle!) { flunk "fixture mode must never consult the pacer -- there is no real network to protect" }

    adapter = Integrations::Prodigi::Adapter.new(mode: :fixture, pacer: pacer)
    adapter.product(sku: "GLOBAL-CFPM-16X24")
    adapter.quote(destination_country: "US", items: [ { sku: "GLOBAL-CFPM-16X24", copies: 1 } ])
    adapter.order_status(order_id: "ord_fixture_1")
  end

  private
    def fake_clock(initial)
      holder = Struct.new(:value).new(initial)
      def holder.call
        value
      end
      holder
    end
end
