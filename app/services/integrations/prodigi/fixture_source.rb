require "json"

module Integrations
  module Prodigi
    class FixtureSource
      ROOT = Rails.root.join("test/fixtures/files/prodigi/v1")
      OPERATIONS = %i[product quote order order_status].freeze
      SCENARIOS = %i[success throttled unauthorized malformed].freeze
      # Every committed fixture file must declare this exact version, so a
      # stale or absent version fails closed as :malformed_response rather
      # than silently reinterpreting an old shape.
      FIXTURE_VERSION = 1

      def initialize(scenario:)
        # An allowlist prevents selectors from becoming arbitrary file paths.
        @scenario = SCENARIOS.find { |allowed| scenario == allowed || scenario == allowed.to_s }
        raise Error.new(:invalid_input) unless @scenario
      end

      def read(operation, request)
        raise Error.new(:invalid_input) unless OPERATIONS.include?(operation)

        fixture = JSON.parse(ROOT.join("#{operation}.json").read)
        raise Error.new(:malformed_response) unless fixture.fetch("fixture_version") == FIXTURE_VERSION

        entries = fixture.fetch("entries")
        raise Error.new(:malformed_response) unless entries.is_a?(Array)

        entry = entries.find { |candidate| candidate.is_a?(Hash) && candidate.fetch("request") == request }
        raise Error.new(:fixture_miss) unless entry

        body = if @scenario == :success
          JSON.generate(entry.fetch("response"))
        else
          ROOT.join("#{@scenario}.json").read
        end
        { body: body, observed_at: fixture.fetch("observed_at") }
      rescue JSON::ParserError, KeyError, Errno::ENOENT
        raise Error.new(:malformed_response), cause: nil
      end
    end
  end
end
