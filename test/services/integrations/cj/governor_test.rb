require "test_helper"

class CjGovernorTest < ActiveSupport::TestCase
  test "fixtures cost zero points and do not invoke the clock or rate gate" do
    policy = Integrations::Cj::ModePolicy.new(deployment: :test)
    governor = Integrations::Cj::Governor.new(policy: policy, clock: -> { flunk "Fixture invoked clock" })
    10.times do
      admission = governor.admit!(purpose: :critical, points: 500)
      assert_equal [ :fixture, :critical, 0 ], [ admission.mode, admission.purpose, admission.points ]
      assert admission.frozen?
    end
    assert_equal({ catalog: 0, critical: 0, recovery: 0 }, governor.remaining)
    assert_error(:invalid_input) { governor.admit!(purpose: :unknown, points: 1) }
    assert_error(:invalid_input) { governor.admit!(purpose: :catalog, points: -1) }
    assert_error(:invalid_input) { Integrations::Cj::Governor.new(policy: policy, points_limit: 1) }
  end

  test "verification and recording cannot exceed hard run ceilings" do
    { verify: [ 500, 300, 150, 50 ], record: [ 2_500, 1_500, 750, 250 ] }.each do |mode, (ceiling, catalog, critical, recovery)|
      policy = policy_for(mode)
      now = 0
      governor = Integrations::Cj::Governor.new(policy: policy, clock: -> { now })
      assert_equal({ catalog: catalog, critical: critical, recovery: recovery }, governor.remaining)
      governor.remaining.each do |purpose, points|
        assert_equal points, governor.admit!(purpose: purpose, points: points).points
        now += 1
      end
      assert_equal 0, governor.remaining.values.sum
      assert_error(:quota_exhausted) { governor.admit!(purpose: :catalog, points: 1) }
      assert_error(:invalid_input) { Integrations::Cj::Governor.new(policy: policy, points_limit: ceiling + 1) }
      smaller = Integrations::Cj::Governor.new(policy: policy, points_limit: 100)
      assert_equal({ catalog: 60, critical: 30, recovery: 10 }, smaller.remaining)
    end
  end

  test "one RPS is shared across purposes and returns deterministic bounded retry delay" do
    now = 100.0
    governor = Integrations::Cj::Governor.new(policy: policy_for, clock: -> { now })
    governor.admit!(purpose: :catalog, points: 2)
    now = 100.25
    error = assert_error(:throttled) { governor.admit!(purpose: :critical, points: 3) }
    assert_equal :backoff, error.retry_strategy
    assert_equal 0.75, error.retry_after
    assert_equal({ catalog: 298, critical: 150, recovery: 50 }, governor.remaining)
    now = 101.0
    governor.admit!(purpose: :critical, points: 3)
    assert_equal 147, governor.remaining[:critical]
  end

  test "rejected quota or invalid input does not consume the next rate slot" do
    governor = Integrations::Cj::Governor.new(policy: policy_for, clock: -> { 10 })
    assert_error(:quota_exhausted) { governor.admit!(purpose: :catalog, points: 301) }
    assert_error(:invalid_input) { governor.admit!(purpose: :catalog, points: "synthetic-secret") }
    assert_equal 1, governor.admit!(purpose: :critical, points: 1).points
  end

  test "invalid clock values and clock failures fail closed without charges or leaked causes" do
    [ nil, -1, "synthetic-secret", Float::INFINITY, Float::NAN ].each do |time|
      governor = Integrations::Cj::Governor.new(policy: policy_for, clock: -> { time })
      assert_error(:unavailable) { governor.admit!(purpose: :catalog, points: 1) }
      assert_equal 300, governor.remaining[:catalog]
    end
    governor = Integrations::Cj::Governor.new(policy: policy_for, clock: -> { raise "synthetic-secret" })
    error = assert_error(:unavailable) { governor.admit!(purpose: :catalog, points: 1) }
    assert_nil error.cause
    assert_equal 300, governor.remaining[:catalog]
  end

  test "clock regression does not reset points or admit early" do
    now = 20
    governor = Integrations::Cj::Governor.new(policy: policy_for, clock: -> { now })
    governor.admit!(purpose: :catalog, points: 1)
    now = 19
    assert_error(:unavailable) { governor.admit!(purpose: :critical, points: 1) }
    now = 21
    governor.admit!(purpose: :critical, points: 1)
    assert_equal({ catalog: 299, critical: 149, recovery: 50 }, governor.remaining)
  end

  test "concurrent admission shares one rate slot and charges exactly once" do
    governor = Integrations::Cj::Governor.new(policy: policy_for, clock: -> { 42 })
    start = Queue.new
    threads = 12.times.map do
      Thread.new do
        start.pop
        governor.admit!(purpose: :critical, points: 5)
        :accepted
      rescue Integrations::Cj::Error => error
        error.code
      end
    end
    12.times { start << true }
    threads.each { |thread| assert thread.join(5), "Governor admission did not finish" }
    assert_equal({ accepted: 1, throttled: 11 }, threads.map(&:value).tally)
    assert_equal 145, governor.remaining[:critical]
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  test "live budgeting requires explicit total and never enables a transport" do
    policy_class = Integrations::Cj::ModePolicy
    policy = policy_class.new(deployment: :production, mode: :live, capability: policy_class::LIVE_CAPABILITY)
    assert_error(:invalid_input) { Integrations::Cj::Governor.new(policy: policy) }
    governor = Integrations::Cj::Governor.new(policy: policy, points_limit: 1_000)
    assert_equal({ catalog: 600, critical: 300, recovery: 100 }, governor.remaining)
    assert_error(:unsupported_mode) { Integrations::Cj::Adapter.new(mode: policy.mode) }
    [ nil, {}, Object.new, :fixture ].each do |invalid|
      assert_error(:invalid_input) { Integrations::Cj::Governor.new(policy: invalid) }
    end
  end

  private

  def policy_for(mode = :verify)
    policy_class = Integrations::Cj::ModePolicy
    capability = mode == :verify ? policy_class::VERIFY_CAPABILITY : policy_class::RECORD_CAPABILITY
    policy_class.new(deployment: :development, mode: mode, capability: capability)
  end

  def assert_error(code, &block)
    error = assert_raises(Integrations::Cj::Error, &block)
    assert_equal code, error.code
    assert_equal "CJ adapter: #{code}", error.message
    error
  end
end
