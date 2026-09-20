require "json"

module Integrations
  module Cj
    class FixtureSource
      ROOT = Rails.root.join("test/fixtures/files/cj/v1")
      OPERATIONS = %i[product inventory freight].freeze
      SCENARIOS = %i[success throttled expired_auth malformed].freeze

      def initialize(scenario:)
        # An allowlist prevents selectors from becoming arbitrary file paths.
        @scenario = SCENARIOS.find { |allowed| scenario == allowed || scenario == allowed.to_s }
        raise Error.new(:invalid_input) unless @scenario
      end

      def read(operation, request)
        raise Error.new(:invalid_input) unless OPERATIONS.include?(operation)

        fixture = JSON.parse(ROOT.join("#{operation}.json").read)
        raise Error.new(:malformed_response) unless fixture.fetch("fixture_version") == 1
        raise Error.new(:fixture_miss) unless fixture.fetch("request") == request

        body = if @scenario == :success
          JSON.generate(fixture.fetch("response"))
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
