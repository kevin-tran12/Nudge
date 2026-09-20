module Integrations
  module Cj
    # Read-only, persistence-independent fixture boundary. No transport exists in
    # this slice; choosing a future network mode always fails closed.
    class Adapter
      attr_reader :mode

      def initialize(mode: :fixture, scenario: :success)
        raise Error.new(:unsupported_mode) unless [ :fixture, "fixture" ].include?(mode)

        @mode = :fixture
        @source = FixtureSource.new(scenario: scenario)
      end

      def product(product_id:)
        call(:product, "product_id" => identifier(product_id))
      end

      def inventory(variant_id:)
        call(:inventory, "variant_id" => identifier(variant_id))
      end

      def freight(origin_country:, destination_country:, items:)
        raise Error.new(:invalid_input) unless items.is_a?(Array) && items.size.between?(1, 100)

        rows = items.map do |item|
          unless item.is_a?(Hash) && item.size == 2 && item.key?(:quantity) && item.key?(:variant_id) &&
              item[:quantity].is_a?(Integer) && item[:quantity].between?(1, 10_000)
            raise Error.new(:invalid_input)
          end
          { "variant_id" => identifier(item[:variant_id]), "quantity" => item[:quantity] }
        end
        raise Error.new(:invalid_input) unless rows.map { |row| row["variant_id"] }.uniq.size == rows.size

        call(:freight, "origin_country" => country(origin_country),
          "destination_country" => country(destination_country), "items" => rows)
      end

      private
        def call(operation, request)
          fixture = @source.read(operation, request)
          Normalizer.new.call(operation: operation, body: fixture.fetch(:body),
            request: request, observed_at: fixture.fetch(:observed_at))
        end

        def identifier(value)
          unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, 200) && value.match?(/\A[A-Za-z0-9_{}-]+\z/)
            raise Error.new(:invalid_input)
          end
          value.dup
        end

        def country(value)
          unless value.is_a?(String) && value.valid_encoding? && value.bytesize == 2 && value.match?(/\A[A-Z]{2}\z/)
            raise Error.new(:invalid_input)
          end

          value.dup
        end
    end
  end
end
