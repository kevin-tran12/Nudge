require "digest"

module TestSupport
  module UniqueData
    def unique_test_value(prefix)
      @unique_test_value_sequence = @unique_test_value_sequence.to_i + 1
      namespace = [ self.class.name, name, Process.pid, @unique_test_value_sequence ].join(":")
      suffix = Digest::SHA256.hexdigest(namespace).first(12)

      "#{prefix.to_s.parameterize}-#{suffix}"
    end
  end
end
