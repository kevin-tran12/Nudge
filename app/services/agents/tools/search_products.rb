module Agents
  module Tools
    # Honest bounded filter over Catalog::ProductReader#list. There is no search/ranking/
    # eligibility engine yet (WP-09), so this never fabricates a relevance score: it is a
    # plain substring match over title/description within a single bounded catalog page.
    class SearchProducts
      DEFAULT_LIMIT = 10
      MAX_LIMIT = Catalog::ProductReader::MAX_LIMIT
      MAX_QUERY_BYTES = 200

      def initialize(product_reader: Catalog::FixtureProductReader.new)
        @product_reader = product_reader
      end

      def call(shopping_session:, arguments:)
        raise ArgumentError, "invalid shopping_session" unless shopping_session.is_a?(ShoppingSession)

        query, limit = validate!(arguments)
        page = @product_reader.list(limit: MAX_LIMIT)
        matches = page.items.select { |product| matches?(product, query) }.first(limit)

        { "query" => query, "count" => matches.length,
          "results" => matches.map { |product| ProductProjection.summary(product) } }
      rescue Catalog::ProductReader::Error
        raise Error.new(:unavailable)
      end

      private
        def validate!(arguments)
          raise Error.new(:invalid_arguments) unless arguments.is_a?(Hash)

          arguments = arguments.stringify_keys
          extra = arguments.keys - %w[query limit]
          raise Error.new(:invalid_arguments) unless extra.empty?

          query = arguments["query"]
          unless query.is_a?(String) && query.valid_encoding? && query.bytesize.between?(1, MAX_QUERY_BYTES)
            raise Error.new(:invalid_arguments)
          end

          limit = arguments.fetch("limit", DEFAULT_LIMIT)
          raise Error.new(:invalid_arguments) unless limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)

          [ query, limit ]
        end

        # Product text is untrusted supplier data: it is compared as an opaque byte
        # sequence only, never interpreted, evaluated, or treated as instruction.
        def matches?(product, query)
          needle = query.downcase
          product.title.downcase.include?(needle) ||
            (product.description && product.description.downcase.include?(needle))
        end
    end
  end
end
