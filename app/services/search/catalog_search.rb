module Search
  # Shopper-facing catalog search: bounded lexical retrieval over
  # search_documents (Search::LexicalRetrieval), resolved back to full
  # Catalog::ProductReader projections so results render through the same
  # card partial as the unfiltered catalog.
  #
  # This never raises for shopper-controlled input. An invalid, blank, or
  # over-long query, an empty index, a lexical miss, or a resolved product the
  # reader can no longer read are all the same observable outcome: an empty
  # result. The query text itself is never interpolated into SQL -- it is
  # only ever handed to Search::LexicalRetrieval, which binds it as a query
  # parameter.
  class CatalogSearch
    MAX_QUERY_BYTES = LexicalRetrieval::MAX_QUERY_BYTES
    DEFAULT_LIMIT = 12

    Result = Data.define(:query, :items)

    def initialize(product_reader:, retrieval: LexicalRetrieval.new)
      @product_reader = product_reader
      @retrieval = retrieval
    end

    def call(query:, limit: DEFAULT_LIMIT)
      return empty_result(query) unless valid_query?(query) && valid_limit?(limit)

      retrieval_result = retrieve(query:, limit:)
      return empty_result(query) if retrieval_result.nil?

      product_ids = retrieval_result.items.filter_map(&:product_id).uniq
      Result.new(query: query, items: resolve(product_ids).freeze).freeze
    end

    private
      def retrieve(query:, limit:)
        @retrieval.call(query: query, limit: limit)
      rescue LexicalRetrieval::Error
        nil
      end

      def valid_query?(query)
        query.is_a?(String) && query.valid_encoding? && query.bytesize.between?(1, MAX_QUERY_BYTES)
      end

      def valid_limit?(limit)
        limit.is_a?(Integer) && limit.between?(1, LexicalRetrieval::MAX_LIMIT)
      end

      def resolve(product_ids)
        return [] if product_ids.empty?

        external_ids_by_product_id = SupplierProduct.where(product_id: product_ids)
          .order(:supplier_id).pluck(:product_id, :external_product_id).to_h

        product_ids.filter_map { |product_id| safe_detail(external_ids_by_product_id[product_id]) }
      end

      def safe_detail(external_id)
        return nil if external_id.nil?

        @product_reader.detail(id: external_id)
      rescue Catalog::ProductReader::Error
        nil
      end

      def empty_result(query)
        Result.new(query: query, items: [].freeze).freeze
      end
  end
end
