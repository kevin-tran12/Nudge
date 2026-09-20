require "digest"
require "json"

module Integrations
  module Cj
    module Webhooks
      class Parser
        MAX_BODY_BYTES = 262_144
        MAX_NESTING = 12
        MAX_COLLECTION_ITEMS = 500
        MAX_NODES = 5_000
        MAX_IDENTIFIER_BYTES = 200

        def call(raw_body:)
          invalid_input! unless raw_body.is_a?(String)
          raise Error.new(:body_too_large) if raw_body.bytesize > MAX_BODY_BYTES

          json_body = raw_body.dup.force_encoding(Encoding::UTF_8)
          malformed! unless json_body.valid_encoding?
          payload = JSON.parse(json_body, max_nesting: MAX_NESTING)
          malformed! unless payload.is_a?(Hash)

          message_id = identifier(payload["messageId"])
          message_type = identifier(payload["messageType"])
          event_type = identifier(payload["type"])
          params = payload["params"]
          malformed! unless params.is_a?(Hash) || params.is_a?(Array)
          validate_json!(payload)

          Contracts.deep_freeze(
            Result.new(
              raw_body: raw_body.b.dup.freeze,
              payload_sha256: Digest::SHA256.hexdigest(raw_body).freeze,
              message_id: message_id,
              message_type: message_type,
              event_type: event_type,
              params: params
            )
          )
        rescue JSON::ParserError, JSON::NestingError, EncodingError
          raise Error.new(:malformed_payload), cause: nil
        end

        private
          def identifier(value)
            malformed! unless value.is_a?(String) && value.valid_encoding?
            malformed! unless value.bytesize.between?(1, MAX_IDENTIFIER_BYTES)
            malformed! if value.match?(/[\u0000-\u001f\u007f]/)
            value.freeze
          end

          def validate_json!(root)
            nodes = 0
            pending = [ root ]

            until pending.empty?
              value = pending.pop
              nodes += 1
              malformed! if nodes > MAX_NODES

              case value
              when Hash
                malformed! if value.size > MAX_COLLECTION_ITEMS
                pending.concat(value.keys, value.values)
              when Array
                malformed! if value.size > MAX_COLLECTION_ITEMS
                pending.concat(value)
              when String
                malformed! unless value.valid_encoding?
              when Float
                malformed! unless value.finite?
              when Integer, TrueClass, FalseClass, NilClass
                nil
              else
                malformed!
              end
            end
          end

          def invalid_input!
            raise Error.new(:invalid_input)
          end

          def malformed!
            raise Error.new(:malformed_payload)
          end
      end
    end
  end
end
