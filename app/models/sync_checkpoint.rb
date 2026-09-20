class SyncCheckpoint < ApplicationRecord
  attribute :state_json, CatalogJsonType.new

  belongs_to :sync_run
end
