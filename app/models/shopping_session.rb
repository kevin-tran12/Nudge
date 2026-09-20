class ShoppingSession < ApplicationRecord
  STATUSES = %w[active expired blocked closed].freeze

  belongs_to :user, optional: true, inverse_of: :shopping_sessions
  has_many :consent_records, inverse_of: :shopping_session
  has_many :turnstile_verifications, inverse_of: :shopping_session
  has_many :ai_access_grants, inverse_of: :shopping_session
  has_many :requirements, inverse_of: :shopping_session, dependent: nil
  has_many :recommendation_runs, inverse_of: :shopping_session, dependent: nil

  validates :status, inclusion: { in: STATUSES }

  def active_at?(time)
    status == "active" && started_at <= time && time < expires_at
  end
end
