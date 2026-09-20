class CatalogMedia < ApplicationRecord
  belongs_to :product, optional: true
  belongs_to :product_variant, optional: true
  belongs_to :supplier_observation, optional: true
end
