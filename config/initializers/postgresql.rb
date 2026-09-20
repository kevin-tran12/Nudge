ActiveSupport.on_load(:active_record_postgresqladapter) do
  self.datetime_type = :timestamptz
end

require "active_record/tasks/database_tasks"

module Nudge
  module PinnedPostgresqlStructureDump
    def dump_schema(db_config, format = db_config.schema_format)
      super.tap do
        next unless format.to_sym == :sql

        structure_path = schema_dump_path(db_config, format)
        next unless structure_path && File.read(structure_path).match?(/CREATE EXTENSION .* vector /)

        Nudge::DatabaseCompatibility.pin_pgvector_structure!(structure_path)
      end
    end
  end
end

ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(Nudge::PinnedPostgresqlStructureDump)
