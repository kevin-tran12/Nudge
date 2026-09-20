class EnableVectorAndSharedFunctions < ActiveRecord::Migration[8.1]
  def up
    Nudge::DatabaseCompatibility.verify_postgresql!(connection)
    execute "CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public VERSION '0.8.5'"
    Nudge::DatabaseCompatibility.verify_pgvector!(connection)

    execute <<~SQL
      CREATE FUNCTION public.nudge_prevent_execution_mode_change()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog
      AS $function$
      BEGIN
        IF NEW.execution_mode IS DISTINCT FROM OLD.execution_mode THEN
          RAISE EXCEPTION USING
            ERRCODE = '23514',
            MESSAGE = format('%I.execution_mode is immutable', TG_TABLE_NAME);
        END IF;

        RETURN NEW;
      END;
      $function$;
    SQL

    execute <<~SQL
      CREATE FUNCTION public.nudge_prevent_row_mutation()
      RETURNS trigger
      LANGUAGE plpgsql
      SET search_path = pg_catalog
      AS $function$
      BEGIN
        RAISE EXCEPTION USING
          ERRCODE = '23514',
          MESSAGE = format('%I rows are immutable', TG_TABLE_NAME);
      END;
      $function$;
    SQL
  end

  def down
    execute "DROP FUNCTION public.nudge_prevent_row_mutation()"
    execute "DROP FUNCTION public.nudge_prevent_execution_mode_change()"
    disable_extension "vector"
  end
end
