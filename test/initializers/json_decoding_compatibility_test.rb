require "test_helper"

class JsonDecodingCompatibilityTest < ActiveSupport::TestCase
  test "ActiveSupport::JSON.decode works despite the json positional-options incompatibility" do
    assert_equal({ "a" => 1 }, ActiveSupport::JSON.decode('{"a":1}'))
  end

  test "decoding tolerates an options hash, which is how ActiveSupport calls it internally" do
    assert_equal({ "a" => 1 }, ActiveSupport::JSON.decode('{"a":1}', {}))
  end

  test "encrypted message round-trips, which is what session cookies depend on" do
    secret = SecureRandom.random_bytes(32)
    encryptor = ActiveSupport::MessageEncryptor.new(secret)
    encrypted = encryptor.encrypt_and_sign({ "session" => "value" })

    assert_equal({ "session" => "value" }, encryptor.decrypt_and_verify(encrypted))
  end

  test "duplicate object keys are still rejected, so the shim does not reintroduce smuggling" do
    assert_raises(::JSON::ParserError) { ::JSON.parse('{"a":1,"a":2}') }
  end
end
