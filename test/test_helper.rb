ENV["RAILS_ENV"] ||= "test"
ENV["PROVIDER_MODE"] ||= "fixture"

abort "Tests require PROVIDER_MODE=fixture" unless ENV["PROVIDER_MODE"] == "fixture"

require "simplecov"
require "tmpdir"

test_lane = ENV.fetch("TEST_LANE", "all")
coverage_root = ENV.fetch("COVERAGE_ROOT") { File.join(Dir.tmpdir, "nudge-coverage") }

SimpleCov.command_name(test_lane)
SimpleCov.coverage_dir(File.join(coverage_root, test_lane))
SimpleCov.start "rails" do
  enable_coverage :branch
  track_files "{app,lib}/**/*.rb"
  add_filter %r{^/app/jobs/application_job\.rb$}
  add_filter %r{^/app/mailers/application_mailer\.rb$}
  add_filter %r{^/app/models/application_record\.rb$}

  if ENV["COVERAGE_ENFORCE"] == "1"
    minimum_coverage line: 80, branch: 60
  end
end

require_relative "../config/environment"
warn "TEST_SCHEMA_MAINTENANCE_REACHED" if ENV["DATABASE_SAFETY_PROBE"] == "1"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].sort.each { |file| require file }

module ActiveSupport
  class TestCase
    parallelize(workers: ENV.fetch("RAILS_TEST_WORKERS", "1").to_i)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include TestSupport::UniqueData
  end
end
