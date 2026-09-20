class ConsentRecord < ApplicationRecord
  class ScopeJsonType < ActiveRecord::Type::Json
    def deserialize(value)
      value.is_a?(String) ? JSON.parse(value) : value
    end
  end

  KINDS = %w[cookie_preferences ai_provider_disclosure].freeze
  DECISIONS = %w[accepted rejected customized].freeze

  belongs_to :shopping_session, inverse_of: :consent_records
  belongs_to :user, optional: true, inverse_of: :consent_records

  attribute :scope_json, ScopeJsonType.new

  scope :current, -> { where(withdrawn_at: nil) }

  validates :consent_kind, inclusion: { in: KINDS }
  validates :decision, inclusion: { in: DECISIONS }
  validates :policy_version, presence: true
end
