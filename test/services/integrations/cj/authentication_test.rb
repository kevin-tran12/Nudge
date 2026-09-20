require "test_helper"

class CjAuthenticationTest < ActiveSupport::TestCase
  FakeClock = Struct.new(:now, :monotonic) do
    def advance(seconds)
      self.now += seconds
      self.monotonic += seconds
    end
  end

  test "returns an immutable capped token without exposing secrets" do
    clock = fake_clock
    credential = Object.new.freeze
    observed = []
    transport = lambda do |credential:|
      assert_same self.credential, credential
      { value: +"synthetic-access-token", expires_at: clock.now + 365.days }
    end
    self.credential = credential
    authentication, governor = build_authentication(clock:, credential_source: -> { credential }, transport:,
      observer: ->(event, attributes) { observed << [ event, attributes ] })

    result = authentication.fetch

    assert_equal :refreshed, result.code
    assert_equal "synthetic-access-token", result.token.value
    assert_equal clock.now + 180.days, result.token.expires_at
    assert result.frozen?
    assert result.token.frozen?
    assert result.token.value.frozen?
    assert_raises(FrozenError) { result.token.value << "changed" }
    refute_includes result.inspect, "synthetic-access-token"
    refute_includes result.token.inspect, "synthetic-access-token"
    refute_includes observed.inspect, "synthetic-access-token"
    assert_equal [ :refresh_started, :refresh_succeeded ], observed.map(&:first)
    assert_equal 9, governor.remaining[:recovery]
  ensure
    self.credential = nil
  end

  test "reuses a healthy token and refreshes it before the returned expiry" do
    clock = fake_clock
    responses = [
      { value: "first-token", expires_at: clock.now + 2.days },
      { value: "second-token", expires_at: clock.now + 30.days }
    ]
    calls = 0
    transport = ->(credential:) { calls += 1; responses.fetch(calls - 1) }
    authentication, = build_authentication(clock:, transport:, refresh_before: 1.day)

    first = authentication.fetch
    cached = authentication.fetch
    clock.advance(1.day + 1)
    refreshed = authentication.fetch

    assert_equal :refreshed, first.code
    assert_equal :cached, cached.code
    assert_same first.token, cached.token
    assert_equal "second-token", refreshed.token.value
    assert_equal 2, calls
  end

  test "single flights a concurrent refresh" do
    clock = fake_clock
    entered = Queue.new
    release = Queue.new
    calls = 0
    transport = lambda do |credential:|
      calls += 1
      entered << true
      release.pop
      { value: "shared-token", expires_at: clock.now + 30.days }
    end
    authentication, = build_authentication(clock:, transport:)
    start = Queue.new
    threads = 12.times.map do
      Thread.new do
        start.pop
        authentication.fetch
      end
    end
    12.times { start << true }
    entered.pop
    release << true
    threads.each { |thread| assert thread.join(5), "authentication caller did not finish" }

    results = threads.map(&:value)
    assert_equal 1, calls
    assert_equal({ refreshed: 1, cached: 11 }, results.map(&:code).tally)
    assert_equal 1, results.map { |result| result.token.object_id }.uniq.size
  ensure
    release << true if release && release.empty?
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  test "retries a transient failure once through the governor" do
    clock = fake_clock
    waits = []
    calls = 0
    transport = lambda do |credential:|
      calls += 1
      raise Integrations::Cj::Error.new(:unavailable), cause: nil if calls == 1

      { value: "retried-token", expires_at: clock.now + 30.days }
    end
    authentication, governor = build_authentication(clock:, transport:,
      waiter: ->(seconds) { waits << seconds; clock.advance(seconds) })

    assert_equal "retried-token", authentication.fetch.token.value
    assert_equal 2, calls
    assert_equal [ 1.0 ], waits
    assert_equal 8, governor.remaining[:recovery]
  end

  test "honors throttling without an immediate retry storm" do
    clock = fake_clock
    waits = []
    calls = 0
    transport = lambda do |credential:|
      calls += 1
      raise Integrations::Cj::Governor::Throttled.new(4.5), cause: nil if calls == 1

      { value: "throttle-retry-token", expires_at: clock.now + 30.days }
    end
    authentication, = build_authentication(clock:, transport:,
      waiter: ->(seconds) { waits << seconds; clock.advance(seconds) })

    assert_equal "throttle-retry-token", authentication.fetch.token.value
    assert_equal 2, calls
    assert_equal [ 4.5 ], waits
  end

  test "bounds repeated transient failures and sanitizes causes" do
    clock = fake_clock
    calls = 0
    transport = lambda do |credential:|
      calls += 1
      raise "synthetic-secret-provider-failure"
    end
    authentication, = build_authentication(clock:, transport:,
      waiter: ->(seconds) { clock.advance(seconds) })

    error = assert_error(:unavailable) { authentication.fetch }

    assert_equal 2, calls
    assert_nil error.cause
    refute_includes error.full_message, "synthetic-secret-provider-failure"

    classified, = build_authentication(clock:,
      transport: lambda { |credential:|
        provider_cause = RuntimeError.new("synthetic-secret-classified-cause")
        raise Integrations::Cj::Error.new(:unavailable), cause: provider_cause
      }, waiter: ->(seconds) { clock.advance(seconds) })
    error = assert_error(:unavailable) { classified.fetch }
    assert_nil error.cause
    refute_includes error.full_message, "synthetic-secret-classified-cause"
  end

  test "terminal authentication failure pauses calls until explicit recovery" do
    clock = fake_clock
    observed = []
    calls = 0
    transport = lambda do |credential:|
      calls += 1
      raise Integrations::Cj::Error.new(:authentication_failed), cause: nil if calls == 1

      { value: "recovered-token", expires_at: clock.now + 30.days }
    end
    authentication, = build_authentication(clock:, transport:,
      observer: ->(event, attributes) { observed << [ event, attributes ] })

    assert_error(:authentication_failed) { authentication.fetch }
    assert authentication.paused?
    assert_error(:authentication_failed) { authentication.fetch }
    assert_equal 1, calls

    authentication.recover!
    assert_equal "recovered-token", authentication.fetch.token.value
    refute authentication.paused?
    assert_equal 2, calls
    assert_equal [ :refresh_started, :authentication_paused, :authentication_recovered,
      :refresh_started, :refresh_retry, :refresh_succeeded ], observed.map(&:first)
    assert observed.all? { |_event, attributes| attributes.keys.all? { |key| %i[attempt code retry_after].include?(key) } }
  end

  test "an expired credential pauses before transport is invoked" do
    clock = fake_clock
    source_calls = 0
    authentication, = build_authentication(clock:,
      credential_source: lambda {
        source_calls += 1
        raise Integrations::Cj::Error.new(:authentication_failed), cause: nil
      }, transport: ->(credential:) { flunk "expired credential reached transport" })

    assert_error(:authentication_failed) { authentication.fetch }
    assert authentication.paused?
    assert_error(:authentication_failed) { authentication.fetch }
    assert_equal 1, source_calls
  end

  test "malformed and already expired token responses fail closed and pause" do
    clock = fake_clock
    malformed = [ nil, {}, { value: "", expires_at: clock.now + 1.day },
      { value: "token", expires_at: "tomorrow" }, { value: "token", expires_at: clock.now } ]

    malformed.each do |response|
      authentication, = build_authentication(clock:, transport: ->(credential:) { response })
      code = response.is_a?(Hash) && response[:expires_at].is_a?(Time) && response[:expires_at] <= clock.now ?
        :authentication_failed : :malformed_response
      assert_error(code) { authentication.fetch }
      assert authentication.paused?
    end
  end

  test "clock regression fails closed before cached credentials or transport are used" do
    clock = fake_clock
    calls = 0
    authentication, = build_authentication(clock:, transport: lambda { |credential:|
      calls += 1
      { value: "clock-token", expires_at: clock.now + 30.days }
    })
    authentication.fetch
    clock.now -= 1

    error = assert_error(:unavailable) { authentication.fetch }

    assert_nil error.cause
    assert_equal 1, calls
  end

  test "fixture admission never reads credentials or invokes transport" do
    clock = fake_clock
    policy = Integrations::Cj::ModePolicy.new(deployment: :test)
    governor = Integrations::Cj::Governor.new(policy:)
    authentication = Integrations::Cj::Authentication.new(
      credential_source: -> { flunk "fixture read credentials" },
      transport: ->(credential:) { flunk "fixture invoked transport" }, governor:, clock: -> { clock.now }, points: 1
    )

    assert_error(:unsupported_mode) { authentication.fetch }
  end

  private
    attr_accessor :credential

    def fake_clock
      FakeClock.new(Time.utc(2026, 9, 20, 12), 100.0)
    end

    def build_authentication(clock:, transport:, credential_source: -> { Object.new.freeze }, observer: ->(*) { },
      waiter: ->(seconds) { clock.advance(seconds) }, refresh_before: 7.days)
      policy_class = Integrations::Cj::ModePolicy
      policy = policy_class.new(deployment: :development, mode: :verify,
        capability: policy_class::VERIFY_CAPABILITY)
      governor = Integrations::Cj::Governor.new(policy:, points_limit: 100, clock: -> { clock.monotonic })
      authentication = Integrations::Cj::Authentication.new(credential_source:, transport:, governor:,
        clock: -> { clock.now }, waiter:, observer:, refresh_before:, points: 1, max_attempts: 2)
      [ authentication, governor ]
    end

    def assert_error(code, &block)
      error = assert_raises(Integrations::Cj::Error, &block)
      assert_equal code, error.code
      assert_equal "CJ adapter: #{code}", error.message
      error
    end
end
