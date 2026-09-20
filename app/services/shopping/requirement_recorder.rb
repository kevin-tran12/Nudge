module Shopping
  # Records or supersedes a Requirement from already-extracted, structured
  # input. This service never parses natural language, never calls a model,
  # and never accepts a caller-supplied session/user identifier: identity is
  # resolved server-side and handed in as an already-authorized
  # ShoppingSession (see Identity::CurrentContext).
  #
  # Requirement text/values are untrusted shopper-originated data. They are
  # stored and returned as inert attributes; they are never interpolated
  # into SQL, evaluated, or used to alter control flow.
  class RequirementRecorder
    MAX_ATTEMPTS = 5

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super("Requirement recorder: #{code}")
      end
    end

    PAYLOAD_KEYS = %i[
      requirement_key operator kind value_json value_schema_version source
      confidence importance needs_clarification originating_message_id
      originating_tool_call_id confirmed_at
    ].freeze

    # requirement: a plain Hash of already-extracted, structured fields.
    # Returns the newly active Requirement (superseding any prior active
    # requirement with the same key in this session).
    def record(shopping_session:, requirement:)
      fail!(:invalid_input) unless shopping_session.is_a?(ShoppingSession)
      attrs = extract(requirement)

      with_retry do
        Requirement.transaction do
          current = Requirement.lock.find_by(
            shopping_session_id: shopping_session.id,
            requirement_key: attrs[:requirement_key],
            status: "active"
          )

          new_requirement = Requirement.new(attrs.merge(shopping_session_id: shopping_session.id, status: "active"))
          if current
            new_requirement.supersedes_requirement_id = current.id
            current.status = "superseded"
            current.save!
          end
          new_requirement.save!
          new_requirement
        end
      end
    end

    # Rejects the currently active requirement for the given key, leaving
    # its history in place (no new requirement is created).
    def reject(shopping_session:, requirement_key:)
      fail!(:invalid_input) unless shopping_session.is_a?(ShoppingSession)
      fail!(:invalid_input) unless requirement_key.is_a?(String)

      Requirement.transaction do
        current = Requirement.lock.find_by(
          shopping_session_id: shopping_session.id,
          requirement_key: requirement_key,
          status: "active"
        )
        fail!(:not_found) unless current
        current.update!(status: "rejected")
        current
      end
    end

    private
      def with_retry
        attempts = 0
        begin
          attempts += 1
          yield
        rescue ActiveRecord::RecordInvalid
          raise Error.new(:invalid_input), cause: nil
        rescue ActiveRecord::RecordNotUnique
          raise Error.new(:conflict) if attempts >= MAX_ATTEMPTS
          retry
        end
      end

      def extract(requirement)
        fail!(:invalid_input) unless requirement.is_a?(Hash)
        symbolized_keys = requirement.keys.map { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
        fail!(:invalid_input) unless (symbolized_keys - PAYLOAD_KEYS).empty?

        attrs = requirement.symbolize_keys.slice(*PAYLOAD_KEYS)
        fail!(:invalid_input) unless attrs[:requirement_key].is_a?(String)
        fail!(:invalid_input) unless attrs[:operator].is_a?(String)
        fail!(:invalid_input) unless attrs[:kind].is_a?(String)
        fail!(:invalid_input) unless attrs[:value_json].is_a?(Hash)
        fail!(:invalid_input) unless attrs[:value_schema_version].is_a?(Integer)
        fail!(:invalid_input) unless attrs[:source].is_a?(String)
        fail!(:invalid_input) unless attrs[:confidence].is_a?(Numeric)
        fail!(:invalid_input) unless attrs[:importance].is_a?(Numeric)
        attrs[:needs_clarification] = false unless attrs.key?(:needs_clarification)
        fail!(:invalid_input) unless [ true, false ].include?(attrs[:needs_clarification])
        attrs
      end

      def fail!(code)
        raise Error.new(code), cause: nil
      end
  end
end
