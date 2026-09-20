class SupplierWarehouse < ApplicationRecord
  belongs_to :supplier
  has_many :inventory_observations
end
