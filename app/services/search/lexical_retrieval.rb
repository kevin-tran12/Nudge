module Search
  # Bounded lexical retrieval over search_documents, using the DB-05 STORED tsvector
  # column and its partial GIN index (status = 'active'). This is the exact-match
  # correctness path from TRD §7: no ranking model, no eligibility, no semantic/vector
  # expansion. Shopper query text is untrusted and is only ever passed as a bound query
  # parameter; it is never interpolated into SQL and never interpreted as an instruction.
  class LexicalRetrieval
    MAX_QUERY_BYTES = 200
    DEFAULT_LIMIT = 10
    MAX_LIMIT = 50

    Result = Data.define(:query, :items)
    Item = Data.define(:search_document_id, :product_id, :product_variant_id, :document_kind, :rank)

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super("Search lexical retrieval: #{code}")
      end
    end

    def call(query:, limit: DEFAULT_LIMIT)
      validate_query!(query)
      validate_limit!(limit)

      rows = execute(query:, limit:)
      items = rows.map do |row|
        Item.new(search_document_id: row.fetch("id").to_i, product_id: row["product_id"]&.to_i,
          product_variant_id: row["product_variant_id"]&.to_i, document_kind: row.fetch("document_kind"),
          rank: row.fetch("rank").to_f)
      end

      Result.new(query:, items: items.freeze).freeze
    end

    private
      def validate_query!(query)
        unless query.is_a?(String) && query.valid_encoding? && query.bytesize.between?(1, MAX_QUERY_BYTES)
          raise Error.new(:invalid_query)
        end
      end

      def validate_limit!(limit)
        raise Error.new(:invalid_limit) unless limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT)
      end

      # Bound parameters only: $1/$2 are supplied as typed QueryAttribute binds, never
      # string-substituted into the SQL text.
      def execute(query:, limit:)
        sql = <<~SQL
          SELECT id, product_id, product_variant_id, document_kind,
                 ts_rank(search_vector, plainto_tsquery('english', $1)) AS rank
          FROM search_documents
          WHERE status = 'active'
            AND search_vector @@ plainto_tsquery('english', $1)
          ORDER BY ts_rank(search_vector, plainto_tsquery('english', $1)) DESC, id ASC
          LIMIT $2
        SQL

        binds = [
          bind_attribute("query", query, ActiveRecord::Type::String.new),
          bind_attribute("limit", limit, ActiveRecord::Type::Integer.new)
        ]

        ApplicationRecord.connection.exec_query(sql, "Search::LexicalRetrieval", binds).to_a
      end

      def bind_attribute(name, value, type)
        ActiveRecord::Relation::QueryAttribute.new(name, value, type)
      end
  end
end
