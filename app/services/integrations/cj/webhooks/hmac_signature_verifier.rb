require "active_support/security_utils"
require "base64"
require "openssl"

module Integrations
  module Cj
    module Webhooks
      class HmacSignatureVerifier
        MAX_OPEN_ID_BYTES = 1024
        SIGNATURE_BYTES = 32
        MAX_SIGNATURE_BYTES = 128

        def initialize(open_id:)
          unless open_id.is_a?(String) && open_id.bytesize.between?(1, MAX_OPEN_ID_BYTES)
            raise Error.new(:invalid_input)
          end

          @open_id = open_id.b.dup.freeze
        end

        def verify(raw_body:, signature:)
          return false unless raw_body.is_a?(String)
          return false unless signature.is_a?(String) && signature.bytesize.between?(1, MAX_SIGNATURE_BYTES)

          supplied = Base64.strict_decode64(signature)
          return false unless supplied.bytesize == SIGNATURE_BYTES
          return false unless Base64.strict_encode64(supplied) == signature

          expected = OpenSSL::HMAC.digest("SHA256", @open_id, raw_body)
          ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
        rescue ArgumentError
          false
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
      end
    end
  end
end
