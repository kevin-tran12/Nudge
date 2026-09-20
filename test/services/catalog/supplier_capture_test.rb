require "test_helper"
require "json"

# CAT-SYNC-01. Every byte in this test comes from a stubbed transport: no
# socket is ever opened, and the whole capture/validate/import cycle is
# exercised offline.
class CatalogSupplierCaptureTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  ModePolicy = Integrations::Cj::ModePolicy
  FIXTURE_ROOT = Rails.root.join("test/fixtures/files/cj/v1")
  # Products whose every variant also has an inventory fixture entry.
  CATALOG_PIDS = %w[00002001 00002002 00002003 00002004 00002005 00002006 00002007].freeze

  FakeToken = Struct.new(:value)
  FakeAuthResult = Struct.new(:token)

  class FakeAuthentication
    def fetch
      FakeAuthResult.new(FakeToken.new("synthetic-token"))
    end
  end

  # Stubs the raw HTTP seam: returns provider bytes, never opens a socket.
  class StubTransport
    attr_reader :calls

    def initialize(bodies:, pids:, tamper: nil)
      @bodies = bodies
      @pids = pids
      @tamper = tamper
      @calls = []
    end

    def call(operation:, token:, request:)
      @calls << [ operation, request ]
      body = case operation
      when :product_list then list_body(request)
      when :product then @bodies.fetch(:product).fetch(request.fetch("product_id"))
      when :inventory then @bodies.fetch(:inventory).fetch(request.fetch("variant_id"))
      end
      @tamper ? @tamper.call(operation, request, body) : body
    end

    def authenticate(credential:)
      raise "authenticate must not be reached"
    end

    def count(operation)
      @calls.count { |entry| entry.first == operation }
    end

    private
      def list_body(request)
        page = request.fetch("pageNum")
        size = request.fetch("pageSize")
        rows = @pids.each_slice(size).to_a[page - 1] || []
        JSON.generate("code" => 200, "result" => true, "requestId" => "stub-list-#{page}",
          "data" => { "total" => @pids.size, "list" => rows.map { |pid| summary_row(pid) } })
      end

      def summary_row(pid)
        { "pid" => pid, "productNameEn" => "Stub product #{pid}", "productSku" => "STUB-#{pid}",
          "productImage" => nil, "sellPrice" => nil }
      end
  end

  setup do
    clean_catalog!
    @supplier = Supplier.create!(key: "cj", display_name: "CJ Dropshipping",
      adapter_version: "1", api_version: "v1", status: "active")
    @bodies = { product: entries_by(:product, "product_id"), inventory: entries_by(:inventory, "variant_id") }
  end

  teardown { clean_catalog! }

  test "a full capture and import cycle persists products, variants, inventory, and v1 artifacts" do
    transport = build_transport
    summary = run_capture(transport, max_products: 2, page_size: 2)

    assert_equal 2, summary.products_discovered
    assert_equal 2, summary.products_captured
    assert_equal 2, summary.products_imported
    assert_equal 0, summary.products_skipped
    assert_equal 3, summary.variants_captured
    assert_equal 3, summary.variants_imported
    assert_equal 0, summary.variants_skipped

    assert_equal %w[00002001 00002002],
      SupplierProduct.where(supplier: @supplier).order(:external_product_id).pluck(:external_product_id)
    assert_equal %w[00021011 00021012 00022021],
      SupplierVariant.where(supplier: @supplier).order(:external_variant_id).pluck(:external_variant_id)
    assert_operator InventoryObservation.count, :>, 0

    # Every persisted payload is the exact v1 envelope RecordArtifactValidator emits.
    SupplierObservation.where(supplier: @supplier).find_each do |observation|
      assert_equal Integrations::Cj::RecordArtifactValidator::ARTIFACT_KEYS.sort,
        observation.payload_json.keys.sort
      assert_equal 1, observation.payload_json.fetch("fixture_version")
    end
    assert_equal 0, SyncRun.where(status: "failed").count
  end

  test "replaying the same capture imports nothing new and creates no duplicates" do
    first = run_capture(build_transport, max_products: 2, page_size: 2)
    snapshot = catalog_counts

    second = run_capture(build_transport, max_products: 2, page_size: 2)

    assert_equal first.products_captured, second.products_skipped
    assert_equal 0, second.products_imported
    assert_equal first.variants_captured, second.variants_skipped
    assert_equal 0, second.variants_imported
    assert_equal snapshot, catalog_counts
  end

  test "the product bound is enforced and never fetches more products than asked" do
    transport = build_transport
    summary = run_capture(transport, max_products: 3, page_size: 2)

    assert_equal 3, summary.products_discovered
    assert_equal 3, transport.count(:product)
    assert_equal 2, transport.count(:product_list)
    assert_equal 3, SupplierProduct.count
    assert_equal({ product_list: 2, product: 3, inventory: 5 }, summary.calls)
  end

  test "a tampered response body is rejected before anything is imported" do
    tamper = lambda do |operation, _request, body|
      next body unless operation == :product

      payload = JSON.parse(body)
      payload["data"]["injectedField"] = "tampered"
      JSON.generate(payload)
    end
    transport = build_transport(tamper: tamper)

    error = assert_raises(Catalog::SupplierCapture::Error) { run_capture(transport, max_products: 1, page_size: 1) }

    assert_equal :malformed_response, error.code
    assert_equal 0, SupplierProduct.count
    assert_equal 0, Product.count
  end

  test "a points refusal aborts cleanly without a partially imported product" do
    transport = build_transport
    # catalog partition = 60% of 200 = 120 points: list 50 + product 50 + 2 x inventory 10 = 120.
    error = assert_raises(Catalog::SupplierCapture::Error) do
      run_capture(transport, max_products: 2, page_size: 2, points_limit: 200)
    end

    assert_equal :quota_exhausted, error.code
    assert_equal [ "00002001" ], SupplierProduct.pluck(:external_product_id)
    assert_nil SupplierProduct.find_by(external_product_id: "00002002")
    assert_equal 1, Product.count
  end

  test "a non-record adapter is refused" do
    sink = Catalog::SupplierCapture::RawSink.new
    capture = Catalog::SupplierCapture.new(supplier: @supplier,
      adapter: Integrations::Cj::Adapter.new(raw_sink: sink), sink: sink)

    error = assert_raises(Catalog::SupplierCapture::Error) { capture.call(max_products: 1, category: "x") }

    assert_equal :unsupported_mode, error.code
  end

  test "at least one filter is required and the bound must be a positive integer" do
    transport = build_transport
    [ { max_products: 0 }, { max_products: -1 }, { max_products: "2" },
      { max_products: Catalog::SupplierCapture::MAX_PRODUCTS + 1 } ].each do |options|
      error = assert_raises(Catalog::SupplierCapture::Error) { run_capture(transport, **options) }
      assert_equal :invalid_input, error.code
    end
    error = assert_raises(Catalog::SupplierCapture::Error) do
      run_capture(transport, max_products: 1, category: nil, keyword: nil)
    end
    assert_equal :invalid_input, error.code
  end

  test "the summary reports the points the capture itself spent" do
    summary = run_capture(build_transport, max_products: 1, page_size: 1)

    # one product_list (50) + one product (50) + two inventory (10 each)
    assert_equal 120, summary.points_consumed
  end

  test "the whole cycle opens no socket" do
    refute_socket_opened do
      run_capture(build_transport, max_products: 2, page_size: 2)
    end
    assert_equal 2, SupplierProduct.count
  end

  private
    def build_transport(tamper: nil, pids: CATALOG_PIDS)
      StubTransport.new(bodies: @bodies, pids: pids, tamper: tamper)
    end

    def run_capture(transport, max_products:, page_size: 2, category: "home-goods", keyword: nil,
      points_limit: 2_500, dry_run: false)
      policy = ModePolicy.new(deployment: :development, mode: :record,
        capability: ModePolicy::RECORD_CAPABILITY)
      governor = Integrations::Cj::Governor.new(policy:, points_limit:, clock: fake_monotonic_clock)
      sink = Catalog::SupplierCapture::RawSink.new
      adapter = Integrations::Cj::Adapter.new(mode: :record, deployment: :development,
        capability: ModePolicy::RECORD_CAPABILITY, config: Integrations::Cj::Config.new(api_key: "synthetic"),
        governor:, transport:, authentication: FakeAuthentication.new,
        clock: -> { Time.utc(2026, 9, 20) }, raw_sink: sink)
      Catalog::SupplierCapture.new(supplier: @supplier, adapter:, sink:,
        clock: -> { Time.utc(2026, 9, 21) }).
        call(max_products:, page_size:, category:, keyword:, dry_run:)
    end

    def fake_monotonic_clock
      time = 0.0
      -> { time += 2.0 }
    end

    def entries_by(operation, key)
      fixture = JSON.parse(FIXTURE_ROOT.join("#{operation}.json").read)
      fixture.fetch("entries").to_h do |entry|
        [ entry.fetch("request").fetch(key), JSON.generate(entry.fetch("response")) ]
      end
    end

    def catalog_counts
      { products: Product.count, variants: ProductVariant.count,
        supplier_products: SupplierProduct.count, supplier_variants: SupplierVariant.count,
        media: CatalogMedia.count, observations: SupplierObservation.count,
        inventory: InventoryObservation.count, prices: PriceObservation.count }
    end

    def refute_socket_opened(&block)
      guard = ->(*) { flunk "a socket was opened during an offline capture" }
      TCPSocket.stub(:open, guard) do
        TCPSocket.stub(:new, guard) do
          Net::HTTP.stub(:start, guard, &block)
        end
      end
    end

    def clean_catalog!
      connection = ApplicationRecord.connection
      connection.disable_referential_integrity do
        %w[sync_checkpoints sync_runs catalog_media inventory_observations price_observations
          supplier_observations supplier_warehouses supplier_variants supplier_products product_variants
          products suppliers].each do |table|
          connection.execute("TRUNCATE TABLE #{table} RESTART IDENTITY CASCADE")
        end
      end
    end
end
