require "test_helper"

# Prodigi has exactly two modes -- :fixture and :sandbox -- and no live mode at
# all (a live order spends real fulfillment money, unlike a live Stripe
# checkout session; see Integrations::Prodigi::Transport::HOSTS, which has no
# :live entry). Capability is always compared by identity, never truthiness.
class ProdigiModePolicyTest < ActiveSupport::TestCase
  test "test deployment forces fixture regardless of requested mode or capability" do
    sentinel = Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY

    policy = Integrations::Prodigi::ModePolicy.new(deployment: :test)
    assert_equal :fixture, policy.mode
    assert policy.frozen?

    assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: :test, mode: :sandbox) }
    assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: :test, mode: :sandbox, capability: sentinel) }
    assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: "test", mode: :sandbox, capability: sentinel) }
  end

  test "non-test deployments default to fixture and require the exact sentinel for sandbox" do
    sentinel = Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY

    [ :development, :staging, :production ].each do |deployment|
      assert_equal :fixture, Integrations::Prodigi::ModePolicy.new(deployment: deployment).mode

      policy = Integrations::Prodigi::ModePolicy.new(deployment: deployment, mode: :sandbox, capability: sentinel)
      assert_equal :sandbox, policy.mode

      assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: deployment, mode: :sandbox) }
    end
  end

  test "a capability is checked by identity, never by truthiness -- a boolean or string is rejected" do
    sentinel = Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY
    look_alikes = [ true, "sandbox", :sandbox, sentinel.dup, Object.new.freeze, {}, [], 1 ]

    look_alikes.each do |fake|
      assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: :development, mode: :sandbox, capability: fake) }
      assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: :staging, mode: :sandbox, capability: fake) }
      assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: :production, mode: :sandbox, capability: fake) }
    end
  end

  test "there is no live mode -- only :fixture and :sandbox are ever recognized" do
    assert_equal [ :fixture, :sandbox ], Integrations::Prodigi::ModePolicy::MODES.to_a
    assert Integrations::Prodigi::ModePolicy::MODES.frozen?
    assert Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY.frozen?

    assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: :production, mode: :live) }
    assert_denied do
      Integrations::Prodigi::ModePolicy.new(deployment: :production, mode: :live,
        capability: Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY)
    end
  end

  test "invalid mode and deployment inputs are rejected without coercion" do
    [ nil, true, 1, {}, [], Object.new, "SANDBOX", "sandbox\n" ].each do |input|
      assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: :development, mode: input) }
      assert_denied { Integrations::Prodigi::ModePolicy.new(deployment: input) }
    end
  end

  private

  def assert_denied(&block)
    error = assert_raises(Integrations::Prodigi::Error, &block)
    assert_equal :unsupported_mode, error.code
  end
end
