module Integrations
  module Cj
    module Webhooks
      Result = Data.define(
        :raw_body,
        :payload_sha256,
        :message_id,
        :message_type,
        :event_type,
        :params
      )

      module Contracts
        module_function

        def deep_freeze(value)
          case value
          when Data
            value.to_h.each_value { |child| deep_freeze(child) }
          when Array
            value.each { |child| deep_freeze(child) }
          when Hash
            value.each { |key, child| deep_freeze(key); deep_freeze(child) }
          end
          value.freeze
        end
      end
    end
  end
end
