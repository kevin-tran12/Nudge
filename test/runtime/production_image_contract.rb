require "open3"

excluded_gems = %w[debug rubocop capybara simplecov]
bundle_path = ENV.fetch("BUNDLE_PATH", "/usr/local/bundle")
installed_paths = excluded_gems.flat_map do |name|
  Dir[File.join(bundle_path, "ruby", "*", "{gems,specifications}", "#{name}-*")]
end

abort "Development/test gems remain in the production bundle: #{installed_paths.join(", ")}" if installed_paths.any?

excluded_gems.each do |name|
  _stdout, _stderr, status = Open3.capture3("bundle", "info", name)
  abort "bundle info unexpectedly found #{name}" if status.success?
end

abort "Production bundle check failed" unless system("bundle", "check")
abort "Production image runs as root" if Process.uid.zero?

require_relative "../../config/environment"
Rails.application.eager_load!
