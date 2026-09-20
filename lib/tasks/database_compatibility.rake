namespace :db do
  desc "Verify the approved PostgreSQL and pgvector versions"
  task verify_compatibility: :environment do
    Nudge::DatabaseCompatibility.verify!(ActiveRecord::Base.connection)
    puts "Database compatibility verified: PostgreSQL 18, pgvector 0.8.5"
  end

  desc "Reject an incompatible database before loading the canonical SQL structure"
  task verify_schema_load_compatibility: :environment do
    connection = ActiveRecord::Base.connection
    Nudge::DatabaseCompatibility.verify_postgresql!(connection)
    Nudge::DatabaseCompatibility.verify_pgvector_if_installed!(connection)
  end
end

Rake::Task["db:schema:load"].enhance([ "db:verify_schema_load_compatibility" ]) do
  Nudge::DatabaseCompatibility.verify!(ActiveRecord::Base.connection)
end

Rake::Task["db:prepare"].enhance do
  Nudge::DatabaseCompatibility.verify!(ActiveRecord::Base.connection)
end

Rake::Task["db:schema:dump"].enhance do
  Nudge::DatabaseCompatibility.pin_pgvector_structure!(Rails.root.join("db/structure.sql"))
end
