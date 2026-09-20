module Agents
  module Tools
    # Turns lexical search into an actual recommendation: retrieves candidates via
    # Search::LexicalRetrieval, resolves them to real catalog facts via
    # CandidateResolver, and evaluates each against the session's own active hard
    # Requirements via the deterministic Shopping::EligibilityEvaluator.
    #
    # Every result is annotated with its own verdict ("pass" | "fail" | "unknown") and,
    # per requirement, the evaluator's own reason code. `unknown` is the evaluator's
    # verdict whenever a needed catalog fact is missing, and it is returned verbatim --
    # never coerced into or displayed as a pass. There is no soft-ranking/scoring model:
    # results are ordered by the retrieval's own deterministic order, using only the
    # verdict itself (pass, then unknown, then fail) to break naturally toward more
    # useful results first, never a fabricated relevance score.
    class RecommendProducts
      DEFAULT_LIMIT = 10
      MAX_LIMIT = Catalog::ProductReader::MAX_LIMIT
      MAX_QUERY_BYTES = Search::LexicalRetrieval::MAX_QUERY_BYTES
      VERDICT_ORDER = { "pass" => 0, "unknown" => 1, "fail" => 2 }.freeze

      def initialize(product_reader: Catalog::FixtureProductReader.new, retrieval: Search::LexicalRetrieval.new,
        evaluator: Shopping::EligibilityEvaluator.new)
        @product_reader = product_reader
        @retrieval = retrieval
        @evaluator = evaluator
        @resolver = CandidateResolver.new(product_reader: product_reader)
      end

      def call(shopping_session:, arguments:)
        raise ArgumentError, "invalid shopping_session" unless shopping_session.is_a?(ShoppingSession)

        query, limit = validate!(arguments)
        result = @retrieval.call(query: query, limit: limit)
        candidates = @resolver.resolve(result.items)
        requirements = shopping_session.requirements.active.hard.to_a

        annotated = candidates.each_with_index.map do |candidate, index|
          [ annotate(shopping_session, candidate, requirements), index ]
        end
        ordered = annotated.sort_by { |(projection, index)| [ VERDICT_ORDER.fetch(projection["eligibility"]["verdict"]), index ] }
          .map(&:first)

        { "query" => query, "count" => ordered.length, "results" => ordered }
      rescue Catalog::ProductReader::Error, Search::LexicalRetrieval::Error
        raise Error.new(:unavailable)
      end

      private
        def annotate(shopping_session, candidate, requirements)
          evaluation = @evaluator.call(
            shopping_session: shopping_session, product: candidate.product, catalog_product: candidate.catalog_product,
            variant: candidate.variant, catalog_variant: candidate.catalog_variant, requirements: requirements
          )

          ProductProjection.summary(candidate.catalog_product).merge("eligibility" => eligibility_projection(evaluation, requirements))
        end

        # Zips against the requirements array passed into the evaluator, which returns
        # eligibility_results in that same order -- avoiding a re-lookup of the
        # requirement association per result.
        def eligibility_projection(evaluation, requirements)
          {
            "verdict" => evaluation.overall_eligibility,
            "requirements" => requirements.zip(evaluation.eligibility_results).map do |requirement, result|
              { "requirement_key" => requirement.requirement_key, "outcome" => result.outcome, "reason_code" => result.reason_code }
            end
          }
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
