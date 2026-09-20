module Integrations
  module Cj
    module Webhooks
      class Error < StandardError
        CODES = %i[invalid_input body_too_large invalid_signature malformed_payload].freeze

        attr_reader :code

        def initialize(code)
          raise ArgumentError, "unknown CJ webhook error code" unless CODES.include?(code)

          @code = code
          super("CJ webhook: #{code}")
        end

        def inspect
          "#<#{self.class.name} code=#{code.inspect}>"
        end
      end
    end
  end
end
