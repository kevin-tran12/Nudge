module Integrations
  module Cj
    module Webhooks
      class Verifier
        def initialize(signature_verifier:, parser: Parser.new)
          unless signature_verifier.respond_to?(:verify) && parser.respond_to?(:call)
            raise Error.new(:invalid_input)
          end

          @signature_verifier = signature_verifier
          @parser = parser
        end

        def call(raw_body:, signature:)
          raise Error.new(:invalid_input) unless raw_body.is_a?(String)
          raise Error.new(:body_too_large) if raw_body.bytesize > Parser::MAX_BODY_BYTES

          verified = @signature_verifier.verify(raw_body:, signature:)
          raise Error.new(:invalid_signature) unless verified == true

          @parser.call(raw_body:)
        rescue Error
          raise
        rescue StandardError
          raise Error.new(:invalid_signature), cause: nil
        end

        def inspect
          "#<#{self.class.name} configured>"
        end
      end
    end
  end
end
