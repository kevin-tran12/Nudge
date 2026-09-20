require "digest"

module Shopping
  # Deterministically decides, for a given product (and optionally a single
  # variant of it), whether each active hard Requirement of a shopping
  # session is `pass`, `fail`, or `unknown`, and persists the verdicts to
  # `eligibility_results`.
  #
  # This evaluator never scores, never guesses, and never calls a model.
  # `unknown` is returned whenever the catalog does not carry the fact a
  # requirement needs, and it is never coerced into `pass`.
  #
  # Only `kind: "hard"` requirements gate eligibility here. Soft
  # requirements feed preference ranking, which is a separate package (see
  # PRD section 6.4) and out of scope for this evaluator.
  #
  # Inputs:
  # - `product` / `variant` (optional): the local, normalized catalog
  #   `Product` / `ProductVariant` records the candidate is persisted
  #   against (FK targets for `recommendation_candidates`).
  # - `catalog_product` / `catalog_variant` (optional): the
  #   Catalog::ProductReader DTOs carrying the deterministic facts (price,
  #   availability, measurements) this evaluator reads. Correlating a local
  #   Product/ProductVariant with its catalog DTO is the responsibility of
  #   the caller; this package does not implement catalog linking.
  class EligibilityEvaluator
    EVALUATOR_VERSION = "eligibility-evaluator-v1"
    POLICY_VERSION = "eligibility-policy-v1"
    SEARCH_POLICY_VERSION = "direct-evaluation-v1"
    PURGE_RETENTION = 30.days

    Result = Data.define(:recommendation_run, :recommendation_candidate, :eligibility_results, :overall_eligibility)

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super("Eligibility evaluator: #{code}")
      end
    end

    def call(shopping_session:, product:, catalog_product:, variant: nil, catalog_variant: nil, requirements: nil, now: nil)
      fail!(:invalid_input) unless shopping_session.is_a?(ShoppingSession)
      fail!(:invalid_input) unless product.is_a?(Product)
      fail!(:invalid_input) unless catalog_product.is_a?(Catalog::ProductReader::Product)
      fail!(:invalid_input) if variant && !(variant.is_a?(ProductVariant) && variant.product_id == product.id)
      fail!(:invalid_input) if catalog_variant && !catalog_variant.is_a?(Catalog::ProductReader::Variant)

      now ||= Time.current
      active_requirements = requirements || shopping_session.requirements.active.hard.to_a
      fail!(:invalid_input) unless active_requirements.all? { |requirement| requirement.is_a?(Requirement) }
      fail!(:invalid_input) unless active_requirements.all? { |requirement| requirement.shopping_session_id == shopping_session.id }

      verdicts = active_requirements.map { |requirement| [ requirement, evaluate(requirement, catalog_variant, variant) ] }
      overall = aggregate(verdicts.map { |(_, verdict)| verdict[:outcome] })

      RecommendationRun.transaction do
        run = RecommendationRun.create!(
          shopping_session: shopping_session,
          requirement_set_hash: requirement_set_hash(active_requirements),
          search_policy_version: SEARCH_POLICY_VERSION,
          status: "succeeded",
          started_at: now,
          completed_at: now,
          query_limit: 1,
          candidate_limit: 1,
          result_summary: {},
          result_schema_version: 1,
          history_influenced: false,
          purge_after: now + PURGE_RETENTION
        )

        candidate = RecommendationCandidate.create!(
          recommendation_run: run,
          product: product,
          product_variant: variant,
          retrieval_source: "direct_evaluation",
          retrieval_rank: 1,
          final_eligibility: overall,
          included: false,
          reason_code: "hard_requirements_evaluated"
        )

        results = verdicts.map do |(requirement, verdict)|
          EligibilityResult.create!(
            recommendation_candidate: candidate,
            requirement: requirement,
            outcome: verdict[:outcome],
            evaluator_version: EVALUATOR_VERSION,
            policy_version: POLICY_VERSION,
            reason_code: verdict[:reason_code],
            evaluated_at: now
          )
        end

        Result.new(recommendation_run: run, recommendation_candidate: candidate,
          eligibility_results: results, overall_eligibility: overall).freeze
      end
    end

    private
      def aggregate(outcomes)
        return "pass" if outcomes.empty?
        return "fail" if outcomes.include?("fail")
        return "unknown" if outcomes.include?("unknown")
        "pass"
      end

      def evaluate(requirement, catalog_variant, variant)
        case requirement.requirement_key
        when "price_max", "price_min"
          evaluate_price(requirement, catalog_variant, variant)
        when "in_stock"
          evaluate_availability(requirement, catalog_variant, variant)
        when "weight_max", "weight_min"
          evaluate_measurement(requirement, catalog_variant, variant, :weight)
        when "length_max", "length_min"
          evaluate_measurement(requirement, catalog_variant, variant, :length)
        when "width_max", "width_min"
          evaluate_measurement(requirement, catalog_variant, variant, :width)
        when "height_max", "height_min"
          evaluate_measurement(requirement, catalog_variant, variant, :height)
        else
          { outcome: "unknown", reason_code: "unsupported_requirement_key" }
        end
      end

      def missing_variant?(catalog_variant, variant)
        catalog_variant.nil?
      end

      def evaluate_price(requirement, catalog_variant, variant)
        return { outcome: "unknown", reason_code: "variant_missing" } if missing_variant?(catalog_variant, variant)

        price = catalog_variant.price
        return { outcome: "unknown", reason_code: "price_unknown" } unless price.state == :known

        target = requirement.value_json
        unless target["currency"].is_a?(String) && target["amount_minor"].is_a?(Numeric)
          return { outcome: "unknown", reason_code: "invalid_requirement_value" }
        end
        return { outcome: "unknown", reason_code: "currency_mismatch" } unless price.currency == target["currency"]

        passes = requirement.requirement_key == "price_max" ? price.amount_minor <= target["amount_minor"] : price.amount_minor >= target["amount_minor"]
        passes ? { outcome: "pass", reason_code: "price_within_threshold" } : { outcome: "fail", reason_code: "price_outside_threshold" }
      end

      def evaluate_availability(requirement, catalog_variant, variant)
        return { outcome: "unknown", reason_code: "variant_missing" } if missing_variant?(catalog_variant, variant)

        availability = catalog_variant.availability
        unless availability.state.to_s.in?(%w[available unavailable])
          return { outcome: "unknown", reason_code: "availability_unknown" }
        end

        want_in_stock = requirement.value_json["value"]
        unless [ true, false ].include?(want_in_stock)
          return { outcome: "unknown", reason_code: "invalid_requirement_value" }
        end

        is_available = availability.state == :available
        is_available == want_in_stock ? { outcome: "pass", reason_code: "availability_matched" } : { outcome: "fail", reason_code: "availability_mismatched" }
      end

      def evaluate_measurement(requirement, catalog_variant, variant, dimension)
        return { outcome: "unknown", reason_code: "variant_missing" } if missing_variant?(catalog_variant, variant)

        measurement = catalog_variant.public_send(dimension)
        return { outcome: "unknown", reason_code: "measurement_unknown" } unless measurement.state == :known

        target = requirement.value_json
        unless target["unit"].is_a?(String) && target["value"].is_a?(Numeric)
          return { outcome: "unknown", reason_code: "invalid_requirement_value" }
        end
        return { outcome: "unknown", reason_code: "unit_mismatch" } unless measurement.unit == target["unit"]

        passes = requirement.requirement_key.end_with?("_max") ? measurement.value <= target["value"] : measurement.value >= target["value"]
        passes ? { outcome: "pass", reason_code: "measurement_within_threshold" } : { outcome: "fail", reason_code: "measurement_outside_threshold" }
      end

      def requirement_set_hash(requirements)
        canonical = requirements.map { |requirement| [ requirement.id, requirement.updated_at.to_f ] }.sort
        Digest::SHA256.digest(canonical.to_json)
      end

      def fail!(code)
        raise Error.new(code), cause: nil
      end
  end
end
