class SupplierProduct < ApplicationRecord
  belongs_to :supplier
  belongs_to :product
  belongs_to :latest_observation, class_name: "SupplierObservation", optional: true
  has_many :supplier_variants
end
