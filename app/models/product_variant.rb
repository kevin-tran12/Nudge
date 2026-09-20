class ProductVariant < ApplicationRecord
  attribute :option_summary, CatalogJsonType.new

  belongs_to :product
  has_many :supplier_variants
end
