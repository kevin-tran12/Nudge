class RecommendationRun < ApplicationRecord
  STATUSES = %w[queued running succeeded no_result failed cancelled].freeze

  attribute :result_summary, CatalogJsonType.new

  belongs_to :shopping_session, inverse_of: :recommendation_runs
  has_many :recommendation_candidates, dependent: nil

  validates :status, inclusion: { in: STATUSES }
  validates :search_policy_version, presence: true
  validates :query_limit, numericality: { only_integer: true, greater_than: 0 }
  validates :candidate_limit, numericality: { only_integer: true, greater_than: 0 }
  validates :result_schema_version, numericality: { only_integer: true, greater_than: 0 }
  validate :requirement_set_hash_length
  validate :result_summary_is_object

  private
    def requirement_set_hash_length
      return if requirement_set_hash.nil?
      errors.add(:requirement_set_hash, "must be 32 bytes") unless requirement_set_hash.bytesize == 32
    end

    def result_summary_is_object
      errors.add(:result_summary, "must be a JSON object") unless result_summary.is_a?(Hash)
    end
end
