module TestSupport
  module TestLane
    ROOT = File.expand_path("../..", __dir__)
    EXCLUDED_FROM_FAST = %r{/test/(?:contracts|integration|system)/}
    INTEGRATION_PATH = %r{/test/(?:contracts|integration)/}
    BROWSER_PATH = %r{/test/system/}

    module_function

    def files(lane)
      tests = Dir[File.join(ROOT, "test/**/*_test.rb")].sort

      case lane.to_sym
      when :fast
        tests.reject { |path| normalized(path).match?(EXCLUDED_FROM_FAST) }
      when :integration
        tests.select { |path| normalized(path).match?(INTEGRATION_PATH) }
      when :browser
        tests.select { |path| normalized(path).match?(BROWSER_PATH) }
      else
        raise ArgumentError, "Unknown test lane: #{lane}"
      end
    end

    def normalized(path)
      path.tr("\\", "/")
    end
  end
end
