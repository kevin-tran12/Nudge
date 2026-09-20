class SupplierVariant < ApplicationRecord
  belongs_to :supplier
  belongs_to :product_variant
  belongs_to :supplier_product
  belongs_to :latest_observation, class_name: "SupplierObservation", optional: true
  has_many :price_observations
  has_many :inventory_observations
end
