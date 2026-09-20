class SearchDocument < ApplicationRecord
  belongs_to :product, optional: true
  belongs_to :product_variant, optional: true
end
