module Agents
  module Tools
    # Records one already-extracted, structured shopper requirement through
    # Shopping::RequirementRecorder. This tool never parses natural language itself --
    # the model supplies the structured fields -- and never accepts a caller-supplied
    # session/user identifier; identity is resolved server-side from the trusted
    # shopping_session the controller hands in.
    #
    # `source` is intentionally narrower than Requirement::SOURCES: this tool is the
    # voice-conversation entry point, so it may only record what the shopper said or a
    # direct inference from that, never claim the higher-trust `system_derived`/
    # `history_soft` provenance reserved for server-side derivation.
    class UpdateRequirements
      MAX_KEY_BYTES = 64
      MAX_OPERATOR_BYTES = 32
      MAX_VALUE_JSON_BYTES = 2_000
      ALLOWED_KINDS = %w[hard soft].freeze
      ALLOWED_SOURCES = %w[user_explicit user_inferred].freeze
      ALLOWED_ARGUMENTS = %w[
        requirement_key operator kind value_json value_schema_version source confidence importance needs_clarification
      ].freeze

      def initialize(recorder: Shopping::RequirementRecorder.new)
        @recorder = recorder
      end

      def call(shopping_session:, arguments:)
        raise ArgumentError, "invalid shopping_session" unless shopping_session.is_a?(ShoppingSession)

        payload = validate!(arguments)
        requirement = @recorder.record(shopping_session: shopping_session, requirement: payload)

        { "recorded" => true, "requirement_key" => requirement.requirement_key, "status" => requirement.status }
      rescue Shopping::RequirementRecorder::Error
        raise Error.new(:invalid_arguments)
      end

      private
        def validate!(arguments)
          raise Error.new(:invalid_arguments) unless arguments.is_a?(Hash)

          arguments = arguments.stringify_keys
          extra = arguments.keys - ALLOWED_ARGUMENTS
          raise Error.new(:invalid_arguments) unless extra.empty?

          {
            requirement_key: requirement_key(arguments), operator: operator(arguments), kind: kind(arguments),
            value_json: value_json(arguments), value_schema_version: value_schema_version(arguments),
            source: source(arguments), confidence: unit_interval(arguments, "confidence"),
            importance: unit_interval(arguments, "importance"), needs_clarification: needs_clarification(arguments)
          }
        end

        def requirement_key(arguments)
          value = arguments["requirement_key"]
          unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, MAX_KEY_BYTES) &&
              value.match?(Requirement::REQUIREMENT_KEY_PATTERN)
            raise Error.new(:invalid_arguments)
          end
          value
        end

        def operator(arguments)
          value = arguments["operator"]
          unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, MAX_OPERATOR_BYTES) &&
              value.match?(Requirement::OPERATOR_PATTERN)
            raise Error.new(:invalid_arguments)
          end
          value
        end

        def kind(arguments)
          value = arguments["kind"]
          raise Error.new(:invalid_arguments) unless ALLOWED_KINDS.include?(value)
          value
        end

        # Requirement values are untrusted shopper-originated data: bounded in size and
        # required to be a plain JSON object with string keys, then stored and returned
        # as an inert attribute -- never evaluated or interpolated.
        def value_json(arguments)
          value = arguments["value_json"]
          raise Error.new(:invalid_arguments) unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }

          serialized = value.to_json
          raise Error.new(:invalid_arguments) unless serialized.bytesize.between?(2, MAX_VALUE_JSON_BYTES)
          value
        rescue JSON::GeneratorError
          raise Error.new(:invalid_arguments)
        end

        def value_schema_version(arguments)
          value = arguments["value_schema_version"]
          raise Error.new(:invalid_arguments) unless value.is_a?(Integer) && value.between?(1, 1_000)
          value
        end

        def source(arguments)
          value = arguments["source"]
          raise Error.new(:invalid_arguments) unless ALLOWED_SOURCES.include?(value)
          value
        end

        def unit_interval(arguments, key)
          value = arguments[key]
          unless (value.is_a?(Integer) || value.is_a?(Float)) && value.between?(0, 1)
            raise Error.new(:invalid_arguments)
          end
          value.to_f
        end

        def needs_clarification(arguments)
          return false unless arguments.key?("needs_clarification")

          value = arguments["needs_clarification"]
          raise Error.new(:invalid_arguments) unless [ true, false ].include?(value)
          value
        end
    end
  end
end
