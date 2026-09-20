require "test_helper"

class Identity::BrowserSessionCookieTest < ActiveSupport::TestCase
  include TestSupport::IdentityRecords

  COOKIE_NAME = :nudge_shopping_session

  setup do
    clear_identity_records
    @clock = -> { TestSupport::IdentityRecords::REFERENCE_TIME }
  end

  teardown { clear_identity_records }

  test "writes only a purpose-bound public id and resolves the trusted current context without database writes" do
    user = create_user
    session = create_shopping_session(user:)
    jar = cookie_jar
    service = cookie_service(jar)

    assert_no_difference -> { ShoppingSession.count } do
      assert service.write(shopping_session: session)
      result = service.resolve

      assert_equal session, result.current_shopping_session
      assert_equal user, result.current_user
    end

    raw_cookie = jar[COOKIE_NAME]
    assert_operator raw_cookie.bytesize, :<=, Identity::BrowserSessionCookie::MAX_COOKIE_BYTES
    assert_equal session.public_id, verifier.verified(raw_cookie)
  end

  test "writes bounded secure cookie attributes without a domain" do
    session = create_shopping_session
    jar = cookie_jar

    cookie_service(jar, secure: false).write(shopping_session: session)
    options = written_cookie_options(jar)

    assert_equal "/", options.fetch(:path)
    assert_equal true, options.fetch(:httponly)
    assert_equal :lax, options.fetch(:same_site)
    assert_equal session.expires_at, options.fetch(:expires)
    refute options.key?(:domain)
    assert_equal false, options.fetch(:secure)
  end

  test "forces secure cookies in production even when a caller requests otherwise" do
    session = create_shopping_session
    jar = cookie_jar

    cookie_service(jar, secure: false, environment: "production").write(shopping_session: session)

    assert_equal true, written_cookie_options(jar).fetch(:secure)
  end

  test "rejects untrusted records and never extends an expired session" do
    jar = cookie_jar
    new_session = ShoppingSession.new

    error = assert_raises(Identity::Error) do
      cookie_service(jar).write(shopping_session: new_session)
    end

    assert_equal :invalid_input, error.code
    assert_nil error.cause
    assert_nil jar[COOKIE_NAME]
  end

  test "missing malformed truncated oversized wrong-purpose and nonexistent cookies resolve anonymously and clear" do
    session = create_shopping_session
    invalid_values = [ "broken", "x" * 4_097 ]

    invalid_values.each do |value|
      jar = cookie_jar
      jar[COOKIE_NAME] = value
      assert_nil cookie_service(jar).resolve
      assert_nil jar[COOKIE_NAME]
    end

    valid_jar = cookie_jar
    cookie_service(valid_jar).write(shopping_session: session)
    raw = valid_jar[COOKIE_NAME]

    truncated = cookie_jar
    truncated[COOKIE_NAME] = raw.byteslice(0, raw.bytesize - 1)
    assert_nil cookie_service(truncated).resolve
    assert_nil truncated[COOKIE_NAME]

    wrong_purpose = cookie_jar
    wrong_purpose[COOKIE_NAME] = alternate_verifier.generate(session.public_id)
    assert_nil cookie_service(wrong_purpose).resolve
    assert_nil wrong_purpose[COOKIE_NAME]

    nonexistent = cookie_jar
    nonexistent[COOKIE_NAME] = verifier.generate(SecureRandom.uuid)
    assert_nil cookie_service(nonexistent).resolve
    assert_nil nonexistent[COOKIE_NAME]
  end

  test "inactive future exact-expiry and inactive-user sessions resolve anonymously without durable changes" do
    now = @clock.call
    user = create_user(status: "disabled")
    sessions = [
      create_shopping_session(status: "blocked"),
      create_shopping_session(started_at: now + 1.second, expires_at: now + 1.hour),
      create_shopping_session(started_at: now - 1.hour, expires_at: now),
      create_shopping_session(user:)
    ]

    sessions.each do |session|
      jar = cookie_jar
      jar[COOKIE_NAME] = verifier.generate(session.public_id)

      assert_no_changes -> { session.reload.attributes } do
        assert_nil cookie_service(jar).resolve
      end
      assert_nil jar[COOKIE_NAME]
    end
  end

  test "two jars remain isolated and tampering cannot substitute another public id" do
    first = create_shopping_session
    second = create_shopping_session
    first_jar = cookie_jar
    second_jar = cookie_jar
    cookie_service(first_jar).write(shopping_session: first)
    cookie_service(second_jar).write(shopping_session: second)

    assert_equal first, cookie_service(first_jar).resolve.current_shopping_session
    assert_equal second, cookie_service(second_jar).resolve.current_shopping_session

    tampered = cookie_jar
    raw = first_jar[COOKIE_NAME]
    tampered[COOKIE_NAME] = "#{raw.start_with?("A") ? "B" : "A"}#{raw.byteslice(1..)}"
    assert_nil cookie_service(tampered).resolve
  end

  test "an explicit write overwrites prior browser state and clear removes it" do
    first = create_shopping_session
    second = create_shopping_session
    jar = cookie_jar
    service = cookie_service(jar)

    service.write(shopping_session: first)
    service.write(shopping_session: second)
    assert_equal second, service.resolve.current_shopping_session

    assert service.clear
    assert_nil jar[COOKIE_NAME]
  end

  test "concurrent reads return one session and do not mutate durable state" do
    session = create_shopping_session
    raw_cookie = signed_cookie_for(session)
    results = Queue.new
    before = session.attributes

    threads = 4.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          jar = cookie_jar
          jar[COOKIE_NAME] = raw_cookie
          results << cookie_service(jar).resolve&.current_shopping_session&.id
        end
      end
    end
    threads.each(&:join)

    assert_equal [ session.id ] * 4, 4.times.map { results.pop }.sort
    assert_equal before, session.reload.attributes
  end

  test "a deleted-session race and database failures fail anonymously and clear the cookie" do
    session = create_shopping_session

    deleted = cookie_jar
    deleted[COOKIE_NAME] = signed_cookie_for(session)
    session.delete
    assert_nil cookie_service(deleted).resolve
    assert_nil deleted[COOKIE_NAME]

    failed = cookie_jar
    failed[COOKIE_NAME] = verifier.generate(SecureRandom.uuid)
    original_find_by = ShoppingSession.method(:find_by)
    ShoppingSession.define_singleton_method(:find_by) do |**|
      raise ActiveRecord::ConnectionNotEstablished, "sensitive database detail"
    end
    begin
      assert_nil cookie_service(failed).resolve
    ensure
      ShoppingSession.define_singleton_method(:find_by, original_find_by)
    end
    assert_nil failed[COOKIE_NAME]
  end

  test "signing configuration failure cannot turn an unsigned production cookie into identity" do
    session = create_shopping_session
    jar = cookie_jar
    jar[COOKIE_NAME] = session.public_id
    failed_verifier = Object.new
    failed_verifier.define_singleton_method(:verified) { |*| raise ArgumentError, "missing signing configuration" }

    service = Identity::BrowserSessionCookie.new(
      cookie_jar: jar,
      clock: @clock,
      secure: false,
      environment: "production",
      verifier: failed_verifier
    )

    assert_nil service.resolve
    assert_nil jar[COOKIE_NAME]
    assert_equal true,
      jar.instance_variable_get(:@delete_cookies).fetch(COOKIE_NAME.to_s).fetch(:secure)
  end

  test "inspection JSON YAML Marshal and interpolation never expose cookie contents" do
    session = create_shopping_session
    jar = cookie_jar
    service = cookie_service(jar)
    service.write(shopping_session: session)
    sentinel = jar[COOKIE_NAME]

    [ service.inspect, service.to_s, service.as_json.to_json, "service=#{service}" ].each do |rendered|
      refute_includes rendered, sentinel
      refute_includes rendered, session.public_id
    end
    assert_raises(TypeError) { YAML.dump(service) }
    assert_raises(TypeError) { Marshal.dump(service) }
  end

  private

  def cookie_service(jar, secure: false, environment: "test")
    Identity::BrowserSessionCookie.new(
      cookie_jar: jar,
      clock: @clock,
      secure:,
      environment:
    )
  end

  def cookie_jar
    ActionDispatch::Cookies::CookieJar.build(ActionDispatch::TestRequest.create, {})
  end

  def verifier
    secret = Rails.application.key_generator.generate_key(Identity::BrowserSessionCookie::SIGNING_SALT, 64)
    ActiveSupport::MessageVerifier.new(
      secret,
      digest: "SHA256",
      serializer: Identity::BrowserSessionCookie::STRING_SERIALIZER,
      url_safe: true
    )
  end

  def alternate_verifier
    secret = Rails.application.key_generator.generate_key("another.identity-purpose", 64)
    ActiveSupport::MessageVerifier.new(
      secret,
      digest: "SHA256",
      serializer: Identity::BrowserSessionCookie::STRING_SERIALIZER,
      url_safe: true
    )
  end

  def written_cookie_options(jar)
    jar.instance_variable_get(:@set_cookies).fetch(COOKIE_NAME.to_s)
  end

  def signed_cookie_for(session)
    jar = cookie_jar
    cookie_service(jar).write(shopping_session: session)
    jar[COOKIE_NAME]
  end
end
