require "json"

module Integrations
  module Cj
    class FixtureSource
      ROOT = Rails.root.join("test/fixtures/files/cj/v1")
      OPERATIONS = %i[product inventory freight product_list].freeze
      SCENARIOS = %i[success throttled expired_auth malformed].freeze
      # v2: each operation file holds a collection of request/response entries
      # (v1 held exactly one), looked up by exact request match. Bumped so a
      # stale or absent version still fails closed rather than silently
      # reinterpreting the old single-entry shape.
      FIXTURE_VERSION = 2

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
