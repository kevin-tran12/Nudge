class RecommendationCandidate < ApplicationRecord
  ELIGIBILITIES = %w[pass fail unknown].freeze

  belongs_to :recommendation_run, inverse_of: :recommendation_candidates
  belongs_to :product
  belongs_to :product_variant, optional: true
  has_many :eligibility_results, dependent: nil

  validates :retrieval_source, presence: true
  validates :retrieval_rank, numericality: { only_integer: true, greater_than: 0 }
  validates :final_eligibility, inclusion: { in: ELIGIBILITIES }
  validates :reason_code, presence: true
  validate :final_rank_positive

  private
    def final_rank_positive
      return if final_rank.nil?
      errors.add(:final_rank, "must be greater than 0") unless final_rank.positive?
    end
end
