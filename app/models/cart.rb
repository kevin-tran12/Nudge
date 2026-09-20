class Cart < ApplicationRecord
  STATUSES = %w[active converted abandoned expired].freeze

  belongs_to :shopping_session
  belongs_to :user, optional: true
  has_many :cart_items, inverse_of: :cart, dependent: :destroy
  has_many :cart_mutations, inverse_of: :cart, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :currency, presence: true, format: { with: /\A[A-Z]{3}\z/ }
end
