require "test_helper"

class CjPointsBudgetTest < ActiveSupport::TestCase
  test "partitions independently round down and cannot borrow checkout or recovery reserves" do
    budget = Integrations::Cj::PointsBudget.new(limit: 103)
    assert_equal({ catalog: 61, critical: 30, recovery: 10 }, budget.remaining)
    budget.charge!(purpose: :catalog, points: 61)
    assert_quota { budget.charge!(purpose: :catalog, points: 1) }
    assert_equal({ catalog: 0, critical: 30, recovery: 10 }, budget.remaining)
    budget.charge!(purpose: :critical, points: 30)
    assert_quota { budget.charge!(purpose: :critical, points: 1) }
    assert_equal 10, budget.remaining[:recovery]
    budget.charge!(purpose: :recovery, points: 10)
    assert_quota { budget.charge!(purpose: :recovery, points: 1) }
  end

  test "zero and tiny limits never round reserves up" do
    [ 0, 1 ].each do |limit|
      budget = Integrations::Cj::PointsBudget.new(limit: limit)
      assert_equal({ catalog: 0, critical: 0, recovery: 0 }, budget.remaining)
      assert_quota { budget.charge!(purpose: :critical, points: 1) }
    end
  end

  test "invalid costs purposes and limits are sanitized and never alter the budget" do
    budget = Integrations::Cj::PointsBudget.new(limit: 100)
    [ nil, true, 0, -1, 1.5, "1", "synthetic-secret", {}, Float::INFINITY ].each do |points|
      assert_invalid { budget.charge!(purpose: :catalog, points: points) }
    end
    [ nil, :auth, :order, :webhook, "catalog", {}, "synthetic-secret" ].each do |purpose|
      assert_invalid { budget.charge!(purpose: purpose, points: 1) }
    end
    [ nil, -1, true, 1.5, "100", Float::NAN ].each do |limit|
      assert_invalid { Integrations::Cj::PointsBudget.new(limit: limit) }
    end
    assert_equal({ catalog: 60, critical: 30, recovery: 10 }, budget.remaining)
  end

  test "snapshots are immutable and independent of subsequent charges" do
    budget = Integrations::Cj::PointsBudget.new(limit: 100)
    snapshot = budget.remaining
    assert_raises(FrozenError) { snapshot[:catalog] = 1_000 }
    budget.charge!(purpose: :catalog, points: 1)
    assert_equal 60, snapshot[:catalog]
    assert_equal 59, budget.remaining[:catalog]
  end

  test "concurrent callers cannot overspend a shared pool" do
    budget = Integrations::Cj::PointsBudget.new(limit: 100)
    start = Queue.new
    threads = 20.times.map do
      Thread.new do
        start.pop
        budget.charge!(purpose: :catalog, points: 4)
        :accepted
      rescue Integrations::Cj::Error => error
        error.code
      end
    end
    20.times { start << true }
    threads.each { |thread| assert thread.join(5), "Budget admission did not finish" }
    assert_equal({ accepted: 15, quota_exhausted: 5 }, threads.map(&:value).tally)
    assert_equal({ catalog: 0, critical: 30, recovery: 10 }, budget.remaining)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  private

  def assert_quota(&block)
    error = assert_raises(Integrations::Cj::Error, &block)
    assert_equal :quota_exhausted, error.code
    assert_equal :pause, error.retry_strategy
    assert_equal "CJ adapter: quota_exhausted", error.message
  end

  def assert_invalid(&block)
    error = assert_raises(Integrations::Cj::Error, &block)
    assert_equal :invalid_input, error.code
    assert_equal :never, error.retry_strategy
    assert_equal "CJ adapter: invalid_input", error.message
  end
end
