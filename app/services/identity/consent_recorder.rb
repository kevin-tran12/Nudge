module Identity
  class ConsentRecorder
    Result = Data.define(:record, :created) do
      include Identity::NonSerializable

      def inspect
        "#<#{self.class.name} created=#{created}>"
      end

      def as_json(*)
        { "recorded" => true, "created" => created }
      end

      def to_json(...)
        as_json.to_json(...)
      end
    end

    MAX_POLICY_VERSION_BYTES = 100
    MAX_SCOPE_DEPTH = 8
    MAX_SCOPE_NODES = 256
    MAX_SCOPE_BYTES = 8_192
    MAX_SCOPE_COLLECTION_SIZE = 64
    MAX_SCOPE_KEY_BYTES = 128
    MAX_SCOPE_STRING_BYTES = 2_048
    DECISIONS = %w[accepted rejected customized].freeze

    def initialize(clock: -> { Time.current }, correlation_id_generator: -> { SecureRandom.uuid })
      @clock = clock
      @correlation_id_generator = correlation_id_generator
    end

    def call(shopping_session:, policy_version:, decision:, scope_json:, scope_schema_version:)
      validate_input!(shopping_session, policy_version, decision, scope_json, scope_schema_version)
      normalized_scope = normalize_scope!(scope_json)

      shopping_session.with_lock do
        now = @clock.call
        context = CurrentContext.new.call(shopping_session:, now:)
        current = context.current_shopping_session.consent_records.current.find_by(
          consent_kind: "ai_provider_disclosure", policy_version:
        )
        if current && same_decision?(current, decision, normalized_scope, scope_schema_version)
          next Result.new(record: current, created: false).freeze
        end

        ConsentRecord.transaction(requires_new: true) do
          current&.update!(withdrawn_at: now)
          record = context.current_shopping_session.consent_records.create!(
            user: context.current_user,
            consent_kind: "ai_provider_disclosure",
            policy_version:,
            decision:,
            scope_json: normalized_scope,
            scope_schema_version:,
            recorded_at: now,
            correlation_id: @correlation_id_generator.call
          )
          Result.new(record:, created: true).freeze
        end
      end
    rescue Error => error
      raise Error.new(error.code), cause: nil
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
      fail!(:conflict)
    rescue ActiveRecord::ActiveRecordError, ArgumentError, TypeError
      fail!(:invalid_input)
    rescue StandardError
      fail!(:conflict)
    end

    private
      def validate_input!(session, policy_version, decision, scope_json, scope_schema_version)
        fail!(:invalid_input) unless session.is_a?(ShoppingSession)
        fail!(:invalid_input) unless policy_version.is_a?(String) &&
          policy_version.bytesize.between?(1, MAX_POLICY_VERSION_BYTES) &&
          !policy_version.match?(/[\u0000-\u001f\u007f]/)
        fail!(:invalid_input) unless DECISIONS.include?(decision)
        fail!(:invalid_input) unless scope_json.is_a?(Hash)
        fail!(:invalid_input) unless scope_schema_version.is_a?(Integer) && scope_schema_version.positive?
      end

      def same_decision?(record, decision, scope, schema_version)
        record.decision == decision && record.scope_json == scope && record.scope_schema_version == schema_version
      end


      def normalize_scope!(scope)
        state = { nodes: 0, path: {} }
        normalized = normalize_scope_value!(scope, depth: 0, state:)
        fail!(:invalid_input) if JSON.generate(normalized).bytesize > MAX_SCOPE_BYTES
        normalized
      rescue JSON::GeneratorError
        fail!(:invalid_input)
      end

      def normalize_scope_value!(value, depth:, state:)
        fail!(:invalid_input) if depth > MAX_SCOPE_DEPTH
        state[:nodes] += 1
        fail!(:invalid_input) if state[:nodes] > MAX_SCOPE_NODES

        case value
        when Hash
          normalize_scope_collection!(value, depth:, state:) do
            value.each_with_object({}) do |(key, child), normalized|
              fail!(:invalid_input) unless key.is_a?(String) || key.is_a?(Symbol)
              key = key.to_s
              fail!(:invalid_input) unless key.bytesize.between?(1, MAX_SCOPE_KEY_BYTES)
              fail!(:invalid_input) if normalized.key?(key)
              normalized[key] = normalize_scope_value!(child, depth: depth + 1, state:)
            end
          end
        when Array
          normalize_scope_collection!(value, depth:, state:) do
            value.map { |child| normalize_scope_value!(child, depth: depth + 1, state:) }
          end
        when String
          fail!(:invalid_input) if value.bytesize > MAX_SCOPE_STRING_BYTES
          value.dup
        when Integer, TrueClass, FalseClass, NilClass
          value
        when Float
          fail!(:invalid_input) unless value.finite?
          value
        else
          fail!(:invalid_input)
        end
      end

      def normalize_scope_collection!(value, depth:, state:)
        fail!(:invalid_input) if value.size > MAX_SCOPE_COLLECTION_SIZE
        fail!(:invalid_input) if state[:path].key?(value.object_id)

        state[:path][value.object_id] = true
        yield
      ensure
        state[:path].delete(value.object_id)
      end

      def fail!(code)
        raise Error.new(code), cause: nil
      end
  end
end
