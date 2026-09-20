class HealthController < ApplicationController
  def ready
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.select_value("SELECT 1")
    end

    render json: { status: "ok", database: "ok" }
  rescue ActiveRecord::ActiveRecordError
    Rails.logger.warn(event: "readiness_check_failed", dependency: "database")
    render json: { status: "unavailable", database: "unavailable" }, status: :service_unavailable
  end
end
