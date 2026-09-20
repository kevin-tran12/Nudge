Rails.application.config.after_initialize do
  next unless Rails.env.development? || Rails.env.test?

  peer_environment = Rails.env.test? ? "development" : "test"
  configurations = ActiveRecord::Base.configurations
  current_database = configurations.configs_for(env_name: Rails.env, name: "primary").database
  peer_database = configurations.configs_for(env_name: peer_environment, name: "primary").database

  if current_database == peer_database
    raise "Development and test must use different databases"
  end

  if Rails.env.test? && !current_database.end_with?("_test")
    raise "Test database name must end in _test"
  end
end
