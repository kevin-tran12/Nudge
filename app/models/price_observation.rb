class PriceObservation < ApplicationRecord
  belongs_to :supplier
  belongs_to :supplier_variant
  belongs_to :supplier_observation
end
