class EligibilityResult < ApplicationRecord
  OUTCOMES = %w[pass fail unknown].freeze

  belongs_to :recommendation_candidate, inverse_of: :eligibility_results
  belongs_to :requirement, inverse_of: :eligibility_results

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :evaluator_version, presence: true
  validates :policy_version, presence: true
  validates :reason_code, presence: true
  validates :evaluated_at, presence: true
end
