module Integrations
  module Prodigi
    # Prodigi documents no rate limit (unlike CJ's points-quota Governor), so
    # this adapter self-limits defensively rather than trusting the provider
    # to tell it when to slow down. A simple mutex-guarded window over a
    # monotonic clock: MIN_INTERVAL bounds how fast successive calls may go
    # out, MAX_CALLS_PER_INSTANCE is a hard sanity ceiling per adapter
    # instance so a runaway loop cannot hammer Prodigi indefinitely. Only
    # consulted from Adapter's sandbox path -- fixture mode has no real
    # network to protect, so paying this cost there would be pure overhead.
    class Pacer
      MIN_INTERVAL = 0.5
      MAX_CALLS_PER_INSTANCE = 200

      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @mutex = Mutex.new
        @last_call_at = nil
        @call_count = 0
      end

      def throttle!
        @mutex.synchronize do
          now = @clock.call

          if @call_count >= MAX_CALLS_PER_INSTANCE
            raise Error.new(:throttled, retry_after: MIN_INTERVAL), cause: nil
          end

          if @last_call_at && (now - @last_call_at) < MIN_INTERVAL
            raise Error.new(:throttled, retry_after: MIN_INTERVAL - (now - @last_call_at)), cause: nil
          end

          @last_call_at = now
          @call_count += 1
        end
        nil
      end
    end
  end
end
