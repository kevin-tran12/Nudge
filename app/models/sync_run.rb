class SyncRun < ApplicationRecord
  attribute :scope_json, CatalogJsonType.new

  belongs_to :supplier
  has_many :sync_checkpoints
end
