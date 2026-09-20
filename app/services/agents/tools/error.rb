module Agents
  module Tools
    class Error < StandardError
      CODES = %i[invalid_arguments not_found unavailable].freeze

      attr_reader :code

      def initialize(code)
        raise ArgumentError, "unknown tool error code" unless CODES.include?(code)

        @code = code
        super("Agents::Tools: #{code}")
      end

      def as_json(*)
        { "code" => code.to_s }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end
  end
end
