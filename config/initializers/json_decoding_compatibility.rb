# ActiveSupport 8.1.3.1 calls ::JSON.parse(json, options) positionally, while
# json 3.x accepts parser options only as keywords. Every ActiveSupport::JSON.decode
# therefore raises ArgumentError, which breaks encrypted cookie decryption, session
# handling, and every JSON request body. The failure is invisible in most tests
# because they do not round-trip an encrypted cookie through a real browser.
#
# Downgrading json to 2.x is not an acceptable fix. json 3 rejects duplicate object
# keys by default and json 2 silently keeps the last one, and the supplier webhook
# verifier and record-artifact validator depend on that rejection to prevent JSON
# smuggling in signed payloads. Downgrading trades a crash for a quiet security
# regression.
#
# Remove this shim once ActiveSupport passes parser options as keywords.
require "active_support/json/decoding"

module ActiveSupport
  module JSON
    class << self
      def decode(json, options = {})
        keywords = options.is_a?(Hash) ? options.transform_keys(&:to_sym) : {}
        data = ::JSON.parse(json, **keywords)

        ActiveSupport.parse_json_times ? convert_dates_from(data) : data
      end
      alias_method :load, :decode
    end
  end
end
