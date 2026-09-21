require "fileutils"

# Backing logic for `rake prodigi:capture`, split into its own module so
# tests can exercise the filesystem write in isolation without invoking the
# rake task machinery. This task is the operator-run, credential-gated step
# that happens AFTER the boundary layer merges, once a human supplies a real
# Prodigi sandbox key -- it must always refuse before touching the network
# when SKUS/credentials/mode are not exactly right, and it never prints the
# credential value itself.
module ProdigiCapture
  CAPTURE_ROOT = Rails.root.join(".planning/prodigi-captures")
  MAX_SKUS = 60

  # Writes exactly the raw provider bytes handed to it -- no reformatting,
  # no reparsing -- so a captured artifact can later be diffed against a
  # real Prodigi response without this task's own round-trip masking a
  # difference, the same lesson the CJ adapter's hand-written fixtures
  # already taught this repo the hard way.
  def self.write_capture(root, operation, id, body)
    dir = root.join(operation.to_s)
    FileUtils.mkdir_p(dir)
    dir.join("#{id}.json").write(body)
  end

  def self.skus_from_env
    raw = ENV["SKUS"]
    if raw.nil? || raw.strip.empty?
      abort("prodigi:capture: the SKUS environment variable is required (comma-separated list of SKUs).")
    end

    skus = raw.split(",").map(&:strip).reject(&:empty?)
    if skus.empty?
      abort("prodigi:capture: the SKUS environment variable is required (comma-separated list of SKUs).")
    end
    if skus.size > MAX_SKUS
      abort("prodigi:capture: at most #{MAX_SKUS} SKUs are allowed per run, got #{skus.size}.")
    end

    skus
  end

  # One combined check: refuses the same clear way whether the cause is a
  # missing credential, a non-sandbox mode, or both, and never echoes the
  # configured credential value.
  def self.require_sandbox_config!
    config = Rails.application.config.x.prodigi
    return if config.sandbox?

    abort("prodigi:capture: requires PRODIGI_MODE=sandbox and a configured PRODIGI_API_KEY credential.")
  end
end

namespace :prodigi do
  desc "Capture real Prodigi sandbox responses for SKUS=sku1,sku2,... (operator-run, credential-gated)"
  task capture: :environment do
    skus = ProdigiCapture.skus_from_env
    ProdigiCapture.require_sandbox_config!

    # ModePolicy still gates the deployment itself: a test deployment (or
    # any deployment lacking the sandbox capability sentinel) fails closed
    # here even when SKUS/credentials both look right above. This is the
    # same capability-sentinel discipline as every other adapter entry
    # point, not an operator-facing usage error, so it is deliberately
    # allowed to raise rather than print-and-exit like the checks above.
    adapter = Integrations::Prodigi::Adapter.build(
      capability: Integrations::Prodigi::ModePolicy::SANDBOX_CAPABILITY,
      raw_sink: lambda do |operation:, request:, body:, observed_at:|
        id = request["sku"] || request["order_id"] || request["idempotency_key"]
        ProdigiCapture.write_capture(ProdigiCapture::CAPTURE_ROOT, operation, id, body)
      end
    )

    skus.each { |sku| adapter.product(sku: sku) }
  end
end
