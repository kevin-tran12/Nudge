class SupplierObservation < ApplicationRecord
  self.filter_attributes += %i[payload_json payload_ciphertext]

  attribute :payload_json, CatalogJsonType.new

  belongs_to :supplier
  has_many :price_observations
  has_many :inventory_observations
end
