module Integrations
  module Cj
    # Share one instance across all callers in a bounded process/run. This is not
    # a distributed daily quota: restarts lose state. Future transport integration
    # must provide durable/global coordination before any real provider traffic.
    # Admission spends conservatively before dispatch; it is never refunded.
    class Governor
      Admission = Data.define(:mode, :purpose, :points)

      class Throttled < Error
        attr_reader :retry_after

        def initialize(retry_after)
          @retry_after = retry_after
          super(:throttled)
        end
      end

      def initialize(policy:, points_limit: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        raise Error.new(:invalid_input), cause: nil unless policy.instance_of?(ModePolicy)

        limit = points_limit.nil? ? policy.ceiling : points_limit
        unless limit.is_a?(Integer) && limit >= 0 && (policy.ceiling.nil? || limit <= policy.ceiling)
          raise Error.new(:invalid_input), cause: nil
        end

        @mode = policy.mode
        @budget = PointsBudget.new(limit: limit)
        @clock = clock
        @mutex = Mutex.new
      end

      def admit!(purpose:, points:)
        PointsBudget.validate_request!(purpose: purpose, points: points)
        return Admission.new(mode: @mode, purpose: purpose, points: 0) if @mode == :fixture

        @mutex.synchronize do
          now = monotonic_time
          if @last_request_at && (elapsed = now - @last_request_at) < 1
            raise Throttled.new(1 - elapsed), cause: nil
          end

          @budget.charge!(purpose: purpose, points: points)
          @last_request_at = now
          Admission.new(mode: @mode, purpose: purpose, points: points)
        end
      end

      def remaining
        @budget.remaining
      end

      private

      def monotonic_time
        now = @clock.call
        unless (now.is_a?(Integer) || now.is_a?(Float)) && now.finite? && now >= 0 &&
            (@last_seen_at.nil? || now >= @last_seen_at)
          raise Error.new(:unavailable)
        end
        @last_seen_at = now
      rescue StandardError
        raise Error.new(:unavailable), cause: nil
      end
    end
  end
end
