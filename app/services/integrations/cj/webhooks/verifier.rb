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
        rescue Error => error
          code = Error::CODES.include?(error.code) ? error.code : :invalid_signature
          raise Error.new(code), cause: nil
        rescue StandardError
          raise Error.new(:invalid_signature), cause: nil
        end

        def inspect
          "#<#{self.class.name} configured>"
        end

        def as_json(*)
          { "configured" => true }
        end

        def to_json(...)
          as_json.to_json(...)
        end

        def encode_with(*)
          raise TypeError, "CJ webhook verifier serialization is disabled"
        end

        def marshal_dump
          raise TypeError, "CJ webhook verifier serialization is disabled"
        end
      end
    end
  end
end
