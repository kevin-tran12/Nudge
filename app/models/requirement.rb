class Requirement < ApplicationRecord
  KINDS = %w[hard soft].freeze
  SOURCES = %w[user_explicit user_inferred system_derived history_soft].freeze
  STATUSES = %w[active rejected superseded].freeze
  REQUIREMENT_KEY_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/
  OPERATOR_PATTERN = /\A[a-z][a-z0-9_]{0,31}\z/

  attribute :value_json, CatalogJsonType.new

  belongs_to :shopping_session, inverse_of: :requirements
  belongs_to :supersedes_requirement, class_name: "Requirement", optional: true,
    inverse_of: :superseded_by_requirement
  has_one :superseded_by_requirement, class_name: "Requirement",
    foreign_key: :supersedes_requirement_id, inverse_of: :supersedes_requirement, dependent: nil

  has_many :eligibility_results, dependent: nil

  scope :active, -> { where(status: "active") }
  scope :hard, -> { where(kind: "hard") }

  validates :requirement_key, presence: true, format: { with: REQUIREMENT_KEY_PATTERN }
  validates :operator, presence: true, format: { with: OPERATOR_PATTERN }
  validates :kind, inclusion: { in: KINDS }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :importance, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :value_schema_version, numericality: { only_integer: true, greater_than: 0 }
  validate :supersedes_requirement_not_self
  validate :value_json_is_object

  def active?
    status == "active"
  end

  private
    def supersedes_requirement_not_self
      return if supersedes_requirement_id.nil? || id.nil?
      errors.add(:supersedes_requirement_id, "cannot reference itself") if supersedes_requirement_id == id
    end

    def value_json_is_object
      errors.add(:value_json, "must be a JSON object") unless value_json.is_a?(Hash)
    end
end
