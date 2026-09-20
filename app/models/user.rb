class User < ApplicationRecord
  STATUSES = %w[active disabled deletion_pending].freeze

  has_many :shopping_sessions, inverse_of: :user
  has_many :consent_records, inverse_of: :user

  validates :status, inclusion: { in: STATUSES }
end
