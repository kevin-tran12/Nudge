require "fileutils"
require "json"
require "net/http"
require "rbconfig"
require "socket"
require "tmpdir"

# Run inside the development image. All writes stay in a disposable application;
# its compiled output directory is deliberately retained between server starts.
class DevelopmentAssetsContract
  SOURCE_ROOT = File.expand_path("../..", __dir__)
  SOURCE_FILES = %w[
    Gemfile Gemfile.lock Rakefile config.ru bin/dev bin/rails
    config/application.rb config/boot.rb config/environment.rb config/database.yml
    config/puma.rb config/storage.yml config/environments/development.rb
    config/initializers/assets.rb
  ].freeze

  def run
    raise "Run this contract as the non-root application user" if Process.uid.zero?

    Dir.mktmpdir("nudge-development-assets-") do |directory|
      @root = directory
      prepare_application
      write_source("first-generation")
      seed_stale_manifest
      assert_production_manifest_preserved
      start_server
      assert_current_css("first-generation")

      write_source("watched-generation")
      assert_current_css("watched-generation")
      stop_server

      # Retain the existing compiled output, just as Compose retains its volume.
      raise "Compiled output was removed" unless File.file?(compiled_path)
      write_source("restarted-generation")
      seed_stale_manifest
      start_server
      assert_current_css("restarted-generation")
      stop_server
    ensure
      stop_server if @pid
    end

    puts "Development assets: stale manifest rejected, watch/restart current, non-root shutdown clean"
  end

  private
    def prepare_application
      SOURCE_FILES.each do |path|
        destination = File.join(@root, path)
        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.cp(File.join(SOURCE_ROOT, path), destination, preserve: true)
      end
      %w[app/controllers app/assets/tailwind app/assets/builds public/assets lib log tmp].each do |path|
        FileUtils.mkdir_p(File.join(@root, path))
      end
      File.write(File.join(@root, "app/controllers/asset_probe_controller.rb"), <<~RUBY)
        class AssetProbeController < ActionController::Base
          def show
            render inline: '<%= stylesheet_link_tag "tailwind" %>'
          end
        end
      RUBY
      File.write(File.join(@root, "config/routes.rb"), <<~RUBY)
        Rails.application.routes.draw { root "asset_probe#show" }
      RUBY
      # This asset-only fixture must not connect to any development/test database.
      File.open(File.join(@root, "config/environments/development.rb"), "a") do |file|
        file.puts "\nRails.application.configure { config.active_record.migration_error = false }"
      end
    end

    def write_source(marker)
      File.write(File.join(@root, "app/assets/tailwind/application.css"), <<~CSS)
        @import "tailwindcss";
        @layer base { :root { --asset-contract-marker: #{marker}; } }
      CSS
    end

    def seed_stale_manifest
      File.write(File.join(@root, "public/assets/tailwind-stale.css"), "/* stale-precompiled-asset */")
      File.write(File.join(@root, "public/assets/.manifest.json"), JSON.generate(
        "tailwind.css" => { "digested_path" => "tailwind-stale.css", "integrity" => nil }
      ))
    end

    def start_server
      socket = TCPServer.new("127.0.0.1", 0)
      @port = socket.addr[1]
      socket.close
      @log = File.open(File.join(@root, "server.log"), "a")
      @pid = Process.spawn(
        { "RAILS_ENV" => "development", "PROVIDER_MODE" => "fixture", "CJ_MODE" => "fixture" },
        RbConfig.ruby, "bin/dev", "-b", "127.0.0.1", "-p", @port.to_s,
        chdir: @root, out: @log, err: @log, pgroup: true
      )
      wait_until("development server startup") { get("/")&.code == "200" }
    end

    def assert_production_manifest_preserved
      success = system(
        { "RAILS_ENV" => "production" },
        RbConfig.ruby, "bin/dev", "--help", chdir: @root, out: File::NULL, err: File::NULL
      )
      raise "Production command failed" unless success
      raise "Production manifest was removed" unless File.file?(File.join(@root, "public/assets/.manifest.json"))
    end

    def assert_current_css(marker)
      wait_until("Tailwind build of #{marker}") do
        File.file?(compiled_path) && File.read(compiled_path).include?(marker)
      end
      page = get("/")
      asset_path = page.body[/href="([^"]+\.css)"/, 1]
      raise "No stylesheet in development response" unless asset_path

      response = get(asset_path)
      unless response&.code == "200" && response.body.include?(marker)
        raise "Development served stale CSS from #{asset_path}; expected #{marker} after Tailwind rebuilt"
      end
    end

    def get(path)
      Net::HTTP.start("127.0.0.1", @port, open_timeout: 1, read_timeout: 1) { |http| http.get(path) }
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout
      nil
    end

    def wait_until(description, timeout: 20)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        raise "Timed out waiting for #{description}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        IO.select(nil, nil, nil, 0.05)
      end
    end

    def compiled_path
      File.join(@root, "app/assets/builds/tailwind.css")
    end

    def stop_server
      pid = @pid
      return unless pid

      Process.kill("TERM", pid)
      wait_until("Puma shutdown", timeout: 8) { Process.waitpid(pid, Process::WNOHANG) }
      status = $?
      unless status.success? || status.termsig == Signal.list.fetch("TERM")
        raise "Puma exited unexpectedly: #{status.inspect}"
      end
      wait_until("Tailwind child shutdown", timeout: 8) do
        begin
          Process.kill(0, -pid)
          false
        rescue Errno::ESRCH
          true
        end
      end
    ensure
      begin
        Process.kill("KILL", -pid) if pid
      rescue Errno::ESRCH
      end
      begin
        Process.waitpid(pid) if pid
      rescue Errno::ECHILD
      end
      @pid = nil
      @log&.close
    end
end

DevelopmentAssetsContract.new.run
