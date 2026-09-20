class InventoryObservation < ApplicationRecord
  belongs_to :supplier
  belongs_to :supplier_variant
  belongs_to :supplier_warehouse
  belongs_to :supplier_observation
end
