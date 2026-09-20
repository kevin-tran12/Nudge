module Agents
  module Tools
    # Lexical retrieval over Search::LexicalRetrieval's tsvector index, resolved back to
    # real catalog facts via CandidateResolver and projected through the allow-listed
    # ProductProjection. There is still no ranking/eligibility model here (that is
    # recommend_products): results are the index's own deterministic order.
    #
    # If no product has been indexed yet (search_documents is empty), this falls back to
    # a plain bounded substring match over Catalog::ProductReader#list so the tool never
    # hard-fails just because CatalogIndexer has not run.
    class SearchProducts
      DEFAULT_LIMIT = 10
      MAX_LIMIT = Catalog::ProductReader::MAX_LIMIT
      MAX_QUERY_BYTES = Search::LexicalRetrieval::MAX_QUERY_BYTES

      def initialize(product_reader: Catalog::FixtureProductReader.new, retrieval: Search::LexicalRetrieval.new)
        @product_reader = product_reader
        @retrieval = retrieval
        @resolver = CandidateResolver.new(product_reader: product_reader)
      end

      def call(shopping_session:, arguments:)
        raise ArgumentError, "invalid shopping_session" unless shopping_session.is_a?(ShoppingSession)

        query, limit = validate!(arguments)
        products = SearchDocument.where(status: "active").exists? ? indexed_products(query, limit) : fallback_products(query, limit)

        { "query" => query, "count" => products.length,
          "results" => products.map { |product| ProductProjection.summary(product) } }
      rescue Catalog::ProductReader::Error, Search::LexicalRetrieval::Error
        raise Error.new(:unavailable)
      end

      private
        def indexed_products(query, limit)
          result = @retrieval.call(query: query, limit: limit)
          @resolver.resolve(result.items).map(&:catalog_product)
        end

        # Honest bounded filter over a single catalog page, used only while the lexical
        # index has nothing in it yet. Product text is untrusted supplier data: it is
        # compared as an opaque byte sequence only, never interpreted or treated as
        # instruction.
        def fallback_products(query, limit)
          page = @product_reader.list(limit: MAX_LIMIT)
          page.items.select { |product| matches?(product, query) }.first(limit)
        end

        def matches?(product, query)
          needle = query.downcase
          product.title.downcase.include?(needle) ||
            (product.description && product.description.downcase.include?(needle))
        end

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
    end
  end
end
