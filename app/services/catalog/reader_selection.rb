module Catalog
  # The single place that decides which ProductReader serves a request.
  #
  # Reader choice used to be a default argument repeated in six unrelated
  # constructors, every one of them Catalog::FixtureProductReader, while only
  # ProductsController selected by environment. The result was a catalog that
  # could show real imported products while the cart resolved variants against
  # fixtures and the voice tools recommended fixture products -- a split view of
  # the world that no single file made visible. Selection lives here so there is
  # one answer, and so a mismatch becomes a change to this file rather than a
  # default argument someone forgot to pass through.
  #
  # READERS is a closed map rather than a class name the caller supplies: an
  # unrecognized value raises the same source_unavailable the unmapped
  # environment already raised, so a typo fails closed and visibly instead of
  # quietly serving fixtures where real data was required.
  module ReaderSelection
    READERS = {
      "fixture" => -> { FixtureProductReader.new },
      "database" => -> { DatabaseProductReader.new }
    }.freeze
    OVERRIDE_KEY = "CATALOG_READER".freeze

    class << self
      def call(environment: Rails.env, env: ENV)
        override = env[OVERRIDE_KEY]
        build(override.nil? ? default_for(environment) : override)
      end

      private
        # Staging and production serve imported supplier data. Local development
        # and test serve fixtures unless CATALOG_READER says otherwise, which is
        # how a developer works against a real local import without pretending
        # the process is production.
        def default_for(environment)
          return "fixture" if environment.local?
          return "database" if environment.staging? || environment.production?

          nil
        end

        def build(name)
          reader = READERS[name]
          raise ProductReader::Error.new(:source_unavailable, retryable: true), cause: nil if reader.nil?

          reader.call
        end
    end
  end
end
