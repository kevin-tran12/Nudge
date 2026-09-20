class CartMutation < ApplicationRecord
  OPERATIONS = %w[add_item change_quantity remove_item].freeze
  STATUSES = %w[pending succeeded failed].freeze

  belongs_to :cart, inverse_of: :cart_mutations
  belongs_to :product_variant

  validates :operation, inclusion: { in: OPERATIONS }
  validates :status, inclusion: { in: STATUSES }
  validates :client_mutation_id, uniqueness: { scope: :cart_id }
end
