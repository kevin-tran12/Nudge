module Integrations
  module Cj
    # One in-memory accounting window. No reset, borrowing, or refund is implicit.
    # Each partition rounds down; fractional remainder stays unallocated.
    class PointsBudget
      SHARES = { catalog: 60, critical: 30, recovery: 10 }.freeze

      def self.validate_request!(purpose:, points:)
        unless SHARES.key?(purpose) && points.is_a?(Integer) && points.positive?
          raise Error.new(:invalid_input), cause: nil
        end
      end

      def initialize(limit:)
        raise Error.new(:invalid_input), cause: nil unless limit.is_a?(Integer) && limit >= 0

        @remaining = SHARES.transform_values { |share| limit * share / 100 }
        @mutex = Mutex.new
      end

      def charge!(purpose:, points:)
        self.class.validate_request!(purpose: purpose, points: points)
        @mutex.synchronize do
          raise Error.new(:quota_exhausted), cause: nil if points > @remaining.fetch(purpose)

          @remaining[purpose] -= points
        end
        points
      end

      def remaining
        @mutex.synchronize { @remaining.dup.freeze }
      end
    end
  end
end
