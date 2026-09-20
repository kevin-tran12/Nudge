class Supplier < ApplicationRecord
  has_many :supplier_products
  has_many :supplier_variants
  has_many :supplier_warehouses
  has_many :supplier_observations
  has_many :sync_runs
end
