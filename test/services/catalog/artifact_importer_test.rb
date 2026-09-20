require "test_helper"
require "stringio"

class CatalogArtifactImporterTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  RECEIVED_AT = Time.utc(2026, 9, 20, 0, 0, 1).freeze

  setup do
    clean_catalog!
    @supplier = Supplier.create!(key: "cj", display_name: "CJ Dropshipping",
      adapter_version: "1", api_version: "v1", status: "active")
    @importer = Catalog::ArtifactImporter.new
  end

  teardown { clean_catalog! }

  test "imports product and variant evidence atomically with exact provenance and audit objects" do
    result = import_product

    assert_equal({ seen: 3, created: 3, updated: 0, errors: 0 }, result.counts)
    assert_equal false, result.replayed?
    assert_equal false, result.dry_run?

    product_ref = SupplierProduct.find_by!(supplier: @supplier, external_product_id: "00001234")
    assert_equal "FIXTURE-BIN", product_ref.external_sku
    assert_equal "observed", product_ref.status
    assert_equal RECEIVED_AT, product_ref.first_seen_at
    assert_equal RECEIVED_AT, product_ref.last_seen_at
    assert_equal RECEIVED_AT, product_ref.last_synced_at
    assert_equal "draft", product_ref.product.status

    measured = SupplierVariant.find_by!(supplier: @supplier, external_variant_id: "00005678")
    assert_equal "FIXTURE-BIN-S", measured.external_variant_sku
    assert_nil measured.product_variant.canonical_sku
    assert_equal "Small bin", measured.product_variant.title
    assert_equal({}, measured.product_variant.option_summary)
    assert_equal 1, measured.product_variant.option_schema_version
    assert_equal BigDecimal("250.5"), measured.weight_value
    assert_equal "g", measured.weight_unit

    canonical = validated(:product)
    observations = SupplierObservation.where(supplier: @supplier).order(:resource_kind, :external_resource_id)
    assert_equal 3, observations.count
    observations.each do |observation|
      assert_equal JSON.parse(canonical.artifact_bytes), observation.payload_json
      assert_equal [ canonical.artifact_sha256 ].pack("H*"), observation.payload_sha256
      assert_equal "product/query", observation.endpoint_key
      assert_equal "fixture-product-1", observation.provider_request_id
      assert_equal "normalized", observation.normalization_status
      assert_equal Time.utc(2026, 9, 20), observation.observed_at
      assert_equal RECEIVED_AT + 30.days, observation.purge_after
    end
    assert_equal "product", product_ref.latest_observation.resource_kind
    assert_equal product_ref.external_product_id, product_ref.latest_observation.external_resource_id
    assert_equal "variant", measured.latest_observation.resource_kind
    assert_equal measured.external_variant_id, measured.latest_observation.external_resource_id

    priced = PriceObservation.find_by!(supplier_variant: measured)
    assert_equal 1_234, priced.amount_minor
    assert_equal "USD", priced.currency
    assert_equal "supplier_sell", priced.price_kind
    unknown_price = SupplierVariant.find_by!(external_variant_id: "fixture-variant-unknown")
    assert_nil PriceObservation.find_by(supplier_variant: unknown_price)
    assert_equal unknown_price.latest_observation_id,
      SupplierObservation.find_by!(resource_kind: "variant", external_resource_id: unknown_price.external_variant_id).id

    run = SyncRun.find(result.sync_run_id)
    assert_equal "succeeded", run.status
    assert_equal "fixture", run.mode
    assert_equal 0, run.points_consumed
    assert_equal %w[artifact_sha256 external_resource_id operation], run.scope_json.keys.sort
    assert_equal "catalog-import:v1:product:#{canonical.artifact_sha256}", run.scope_key
    assert_equal({ "operation" => "product", "external_resource_id" => "00001234",
      "artifact_sha256" => canonical.artifact_sha256 }, run.scope_json)
    checkpoint = run.sync_checkpoints.sole
    assert_equal "artifact_applied", checkpoint.checkpoint_key
    assert_nil checkpoint.cursor
    assert_nil checkpoint.page_number
    assert_equal 1, checkpoint.state_schema_version
    assert_equal %w[artifact_sha256 external_resource_id operation status subject_count], checkpoint.state_json.keys.sort
    assert_equal run.seen_count, checkpoint.state_json.fetch("subject_count")
    assert_equal "applied", checkpoint.state_json.fetch("status")
  end

  test "imports inventory only for an existing same supplier variant and counts warehouses only as created" do
    import_product
    result = @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT)

    assert_equal({ seen: 3, created: 2, updated: 0, errors: 0 }, result.counts)
    variant = SupplierVariant.find_by!(supplier: @supplier, external_variant_id: "00005678")
    assert_equal 2, SupplierWarehouse.where(supplier: @supplier).count
    assert_equal 2, InventoryObservation.where(supplier_variant: variant).count
    assert_equal 1, SupplierObservation.where(supplier: @supplier, resource_kind: "stock").count
    assert_equal "01", SupplierWarehouse.order(:external_warehouse_id).first.external_warehouse_id
    assert_equal 1, SupplierObservation.where(resource_kind: "stock", external_resource_id: "00005678").count
    assert_equal 2, InventoryObservation.count
    assert_equal 2, SupplierVariant.count
    assert_equal 2, ProductVariant.count
    assert_equal "variant", variant.latest_observation.resource_kind
  end

  test "inventory rejects missing and cross supplier variants without any durable or sequence effects" do
    before = durable_snapshot
    error = assert_raises(Catalog::ArtifactImporter::Error) do
      @importer.call(supplier: @supplier, operation: :inventory,
        artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT)
    end
    assert_equal :variant_not_imported, error.code
    assert_equal before, durable_snapshot

    other = Supplier.create!(key: "other", display_name: "Other", adapter_version: "1", api_version: "v1")
    other_product = Product.create!(title: "Other product", description: "", status: "draft")
    other_variant = ProductVariant.create!(product: other_product, title: "Other variant",
      option_summary: {}, option_schema_version: 1, status: "active")
    other_product_ref = SupplierProduct.create!(supplier: other, product: other_product,
      external_product_id: "00001234", status: "observed", first_seen_at: RECEIVED_AT,
      last_seen_at: RECEIVED_AT, last_synced_at: RECEIVED_AT, adapter_version: "1")
    SupplierVariant.create!(supplier: other, product_variant: other_variant,
      supplier_product: other_product_ref, external_variant_id: "00005678", status: "observed",
      first_seen_at: RECEIVED_AT, last_seen_at: RECEIVED_AT, last_synced_at: RECEIVED_AT)
    before = durable_snapshot
    error = assert_raises(Catalog::ArtifactImporter::Error) do
      @importer.call(supplier: @supplier, operation: :inventory,
        artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT)
    end
    assert_equal :variant_not_imported, error.code
    assert_equal before, durable_snapshot
  end

  test "rejects a persisted same-version supplier whose binding key is not cj without sequence allocation" do
    wrong_supplier = Supplier.create!(key: "not-cj", display_name: "Wrong supplier",
      adapter_version: "1", api_version: "v1")
    before = durable_snapshot

    assert_error(:supplier_mismatch) do
      @importer.call(supplier: wrong_supplier, operation: :product,
        artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT)
    end
    assert_equal before, durable_snapshot
  end

  test "inventory rejects a manually assembled variant without prior product import evidence" do
    product = Product.create!(title: "Manual", description: "", status: "draft")
    variant = ProductVariant.create!(product:, title: "Manual", option_summary: {},
      option_schema_version: 1, status: "active")
    product_ref = SupplierProduct.create!(supplier: @supplier, product:, external_product_id: "00001234",
      status: "observed", first_seen_at: RECEIVED_AT, last_seen_at: RECEIVED_AT,
      last_synced_at: RECEIVED_AT, adapter_version: "1")
    SupplierVariant.create!(supplier: @supplier, product_variant: variant, supplier_product: product_ref,
      external_variant_id: "00005678", status: "observed", first_seen_at: RECEIVED_AT,
      last_seen_at: RECEIVED_AT, last_synced_at: RECEIVED_AT)
    before = durable_snapshot

    assert_error(:variant_not_imported) do
      @importer.call(supplier: @supplier, operation: :inventory,
        artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT)
    end
    assert_equal before, durable_snapshot
  end

  test "rejects forged DTOs wrong operations malformed and tampered artifacts" do
    forged = validated(:product)
    assert_error(:invalid_input) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: forged, received_at: RECEIVED_AT) }
    assert_error(:invalid_operation) { @importer.call(supplier: @supplier, operation: :freight,
      artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT) }
    assert_error(:invalid_artifact) { @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT) }
    assert_error(:invalid_artifact) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: "{", received_at: RECEIVED_AT) }

    tampered = fixture_json(:product)
    tampered["response"]["data"]["pid"] = "different"
    assert_error(:invalid_artifact) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(tampered), received_at: RECEIVED_AT) }
    assert_equal 0, SyncRun.count
  end

  test "rejects cross supplier binding" do
    bound = Supplier.create!(key: "cj-bound-00001234", display_name: "Wrong binding",
      adapter_version: "different", api_version: "v1")
    assert_error(:supplier_mismatch) do
      @importer.call(supplier: bound, operation: :product,
        artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT)
    end
    assert_equal 0, SyncRun.count
  end

  test "dry run predicts product and inventory counts without writes or sequence allocation" do
    before = durable_snapshot
    product_result = @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT, dry_run: true)
    assert_equal({ seen: 3, created: 3, updated: 0, errors: 0 }, product_result.counts)
    assert product_result.dry_run?
    assert_equal before, durable_snapshot

    import_product
    before = durable_snapshot
    inventory_result = @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT, dry_run: true)
    assert_equal({ seen: 3, created: 2, updated: 0, errors: 0 }, inventory_result.counts)
    assert_equal before, durable_snapshot
  end

  test "dry-run exact replay reports both replay and dry-run while changing no rows or sequences" do
    first = import_product
    before = durable_snapshot
    replay = @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT, dry_run: true)

    assert replay.replayed?
    assert replay.dry_run?
    assert_equal first.sync_run_id, replay.sync_run_id
    assert_equal first.counts, replay.counts
    assert_equal before, durable_snapshot
  end

  test "exact replay is a no-op before and after payload purge" do
    first = import_product
    before = durable_snapshot
    replay = import_product
    assert replay.replayed?
    assert_equal first.sync_run_id, replay.sync_run_id
    assert_equal before, durable_snapshot

    SupplierObservation.update_all(purge_after: 1.second.ago)
    SupplierObservation.connection.execute("UPDATE supplier_observations SET payload_json = NULL WHERE payload_json IS NOT NULL")
    before = durable_snapshot
    replay = import_product
    assert replay.replayed?
    assert_equal first.sync_run_id, replay.sync_run_id
    assert_equal before, durable_snapshot
  end

  test "preserves lifecycle status and advances receipt timestamps while omission leaves entities unchanged" do
    import_product
    product_ref = SupplierProduct.find_by!(external_product_id: "00001234")
    omitted = SupplierVariant.find_by!(external_variant_id: "fixture-variant-unknown")
    product_ref.update!(status: "paused")
    omitted.update!(status: "paused")
    omitted_before = omitted.attributes

    json = fixture_json(:product)
    json["observed_at"] = "2026-09-20T00:00:02Z"
    json["response"]["requestId"] = "fixture-product-2"
    json["response"]["data"]["productNameEn"] = "Stacking bin revised"
    json["response"]["data"]["variants"] = [ json["response"]["data"]["variants"].first ]
    received = RECEIVED_AT + 2.seconds
    result = @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(json), received_at: received)

    assert_equal({ seen: 2, created: 0, updated: 2, errors: 0 }, result.counts)
    assert_equal "paused", product_ref.reload.status
    assert_equal RECEIVED_AT, product_ref.first_seen_at
    assert_equal received, product_ref.last_seen_at
    assert_equal received, product_ref.last_synced_at
    assert_equal omitted_before, omitted.reload.attributes
  end

  test "newer product evidence counts every changed latest pointer in apply and dry run" do
    import_product
    newer = fixture_json(:product)
    newer["observed_at"] = "2026-09-20T00:00:01Z"
    newer["response"]["requestId"] = "new-pointer-only"
    bytes = JSON.generate(newer)

    before = durable_snapshot
    predicted = @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: bytes, received_at: RECEIVED_AT, dry_run: true)
    assert_equal({ seen: 3, created: 0, updated: 3, errors: 0 }, predicted.counts)
    assert_equal before, durable_snapshot

    applied = @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: bytes, received_at: RECEIVED_AT)
    assert_equal predicted.counts, applied.counts
    assert_equal 3, SupplierObservation.where(provider_request_id: "new-pointer-only").count
  end

  test "rejects future stale equal-time conflict and decreasing receipt time" do
    future = fixture_json(:product)
    future["observed_at"] = "2026-09-20T00:00:02Z"
    assert_error(:future_artifact) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(future), received_at: RECEIVED_AT) }

    import_product
    conflict = fixture_json(:product)
    conflict["response"]["requestId"] = "different"
    assert_error(:temporal_conflict) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(conflict), received_at: RECEIVED_AT + 1.second) }

    stale = fixture_json(:product)
    stale["observed_at"] = "2026-09-19T23:59:59Z"
    assert_error(:stale_artifact) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(stale), received_at: RECEIVED_AT + 1.second) }

    fresh = fixture_json(:product)
    fresh["observed_at"] = "2026-09-20T00:00:02Z"
    fresh["response"]["requestId"] = "fresh"
    @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(fresh), received_at: RECEIVED_AT + 10.seconds)
    newer_capture_old_receipt = fixture_json(:product)
    newer_capture_old_receipt["observed_at"] = "2026-09-20T00:00:03Z"
    assert_error(:decreasing_receipt_time) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(newer_capture_old_receipt), received_at: RECEIVED_AT + 3.seconds) }
  end

  test "rejects precision title and duplicated byte budget boundaries before mutation" do
    too_precise = fixture_json(:product)
    too_precise["response"]["data"]["variants"][0]["variantWeight"] = "0.00001"
    assert_error(:decimal_not_representable) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(too_precise), received_at: RECEIVED_AT) }

    blank_title = fixture_json(:product)
    blank_title["response"]["data"]["variants"][0]["variantNameEn"] = "   "
    assert_error(:blank_title) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(blank_title), received_at: RECEIVED_AT) }

    many = fixture_json(:product)
    source = many["response"]["data"]["variants"].first
    many["response"]["data"]["description"] = "x" * 16_000
    many["response"]["data"]["variants"] = 200.times.map do |index|
      source.merge("vid" => "variant-#{index}", "variantSku" => "sku-#{index}")
    end
    assert_error(:artifact_budget_exceeded) { @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(many), received_at: RECEIVED_AT) }
    assert_equal 0, Product.count
  end

  test "accepts exact decimal and title boundaries without database rounding" do
    boundary = fixture_json(:product)
    boundary["response"]["data"]["productNameEn"] = "p" * 200
    boundary["response"]["data"]["variants"][0]["variantNameEn"] = "v" * 200
    boundary["response"]["data"]["variants"][0]["variantWeight"] = "9999999999.0000"
    boundary["response"]["data"]["variants"][0]["variantLength"] = "0.0001"
    @importer.call(supplier: @supplier, operation: :product,
      artifact_bytes: JSON.generate(boundary), received_at: RECEIVED_AT)

    variant = SupplierVariant.find_by!(external_variant_id: "00005678")
    assert_equal BigDecimal("9999999999.0000"), variant.weight_value
    assert_equal BigDecimal("0.0001"), variant.length_value
    assert_equal 200, variant.product_variant.title.bytesize
    assert_equal 200, variant.supplier_product.product.title.bytesize
  end

  test "all unknown inventory records a latest stock observation without detail fallback" do
    import_product
    known = @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT)
    assert_equal 2, InventoryObservation.count

    unknown = fixture_json(:inventory)
    unknown["observed_at"] = "2026-09-20T00:00:02Z"
    unknown["response"]["requestId"] = "unknown-stock"
    unknown["response"]["data"] = [ { "vid" => "00005678", "areaId" => "01", "countryCode" => "CN",
      "totalInventoryNum" => nil, "cjInventoryNum" => nil, "factoryInventoryNum" => nil, "stock" => [] } ]
    result = @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: JSON.generate(unknown), received_at: RECEIVED_AT + 2.seconds)
    latest_run = SyncRun.find(result.sync_run_id)
    assert_equal({ seen: 2, created: 0, updated: 2, errors: 0 }, result.counts)
    latest_observation = SupplierObservation.where(resource_kind: "stock").order(:id).last
    assert_equal 0, InventoryObservation.where(supplier_observation: latest_observation).count
    assert_equal 2, InventoryObservation.count
    assert_equal latest_run.seen_count, latest_run.sync_checkpoints.sole.state_json.fetch("subject_count")
  end

  test "inventory freshness ignores newer pending failed and uncheckpointed stock evidence" do
    import_product
    create_manual_stock_observation!(observed_at: RECEIVED_AT + 10.seconds, status: "pending")
    create_manual_stock_observation!(observed_at: RECEIVED_AT + 11.seconds, status: "failed")
    unproven = create_manual_stock_observation!(observed_at: RECEIVED_AT + 12.seconds, status: "normalized")
    create_uncheckpointed_success_for!(unproven)

    result = @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT + 20.seconds)

    assert_equal({ seen: 3, created: 2, updated: 1, errors: 0 }, result.counts)
    assert_equal 2, SyncRun.where(status: "succeeded", resource_kind: "inventory").count
    assert_equal 1, SyncRun.find(result.sync_run_id).sync_checkpoints.count
  end

  test "inventory freshness rejects evidence proven by a succeeded run and applied checkpoint" do
    import_product
    newer = fixture_json(:inventory)
    newer["observed_at"] = "2026-09-20T00:00:10Z"
    newer["response"]["requestId"] = "newer-applied-stock"
    @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: JSON.generate(newer), received_at: RECEIVED_AT + 10.seconds)

    stale = fixture_json(:inventory)
    stale["observed_at"] = "2026-09-20T00:00:05Z"
    stale["response"]["requestId"] = "stale-stock"
    assert_error(:stale_artifact) do
      @importer.call(supplier: @supplier, operation: :inventory,
        artifact_bytes: JSON.generate(stale), received_at: RECEIVED_AT + 20.seconds)
    end
  end

  test "empty inventory still records explicit current unknown for the existing variant" do
    import_product
    empty = fixture_json(:inventory)
    empty["response"]["data"] = []
    result = @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: JSON.generate(empty), received_at: RECEIVED_AT)

    assert_equal({ seen: 1, created: 0, updated: 0, errors: 0 }, result.counts)
    observation = SupplierObservation.find_by!(resource_kind: "stock", external_resource_id: "00005678")
    assert_empty observation.inventory_observations
    assert_equal "variant", SupplierVariant.find_by!(external_variant_id: "00005678").latest_observation.resource_kind
  end

  test "a mid-import persistence failure rolls back every catalog and evidence mutation" do
    importer_class = Class.new(Catalog::ArtifactImporter) do
      private
        def create_observation!(...)
          @observation_calls = @observation_calls.to_i + 1
          raise ActiveRecord::StatementInvalid, "injected failure" if @observation_calls == 2

          super
        end
    end
    error = assert_raises(Catalog::ArtifactImporter::Error) do
      importer_class.new.call(supplier: @supplier, operation: :product,
        artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT)
    end
    assert_equal :persistence_failed, error.code
    assert_equal 0, Product.count
    assert_equal 0, ProductVariant.count
    assert_equal 0, SupplierProduct.count
    assert_equal 0, SupplierVariant.count
    assert_equal 0, SupplierObservation.count
    failed = SyncRun.sole
    assert_equal "failed", failed.status
    assert_equal({ seen_count: 0, created_count: 0, updated_count: 0, error_count: 1 },
      failed.attributes.symbolize_keys.slice(:seen_count, :created_count, :updated_count, :error_count))
  end

  test "rescued importer failure inside a committed caller transaction cannot preserve partial writes" do
    importer_class = Class.new(Catalog::ArtifactImporter) do
      private
        def create_observation!(...)
          @observation_calls = @observation_calls.to_i + 1
          raise ActiveRecord::StatementInvalid, "outer transaction failure" if @observation_calls == 2

          super
        end
    end

    ApplicationRecord.transaction do
      assert_raises(Catalog::ArtifactImporter::Error) do
        importer_class.new.call(supplier: @supplier, operation: :product,
          artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT)
      end
      Supplier.find(@supplier.id).touch
    end

    assert_equal 0, Product.count
    assert_equal 0, ProductVariant.count
    assert_equal 0, SupplierProduct.count
    assert_equal 0, SupplierVariant.count
    assert_equal 0, SupplierObservation.count
    assert_equal 0, SyncCheckpoint.count
    failed = SyncRun.sole
    assert_equal "failed", failed.status
    assert_equal "persistence_failed", failed.error_code
  end

  test "concurrent exact imports serialize to one success and one replay" do
    results = concurrently(fixture_bytes(:product), fixture_bytes(:product))

    assert_equal 2, results.count { |result| result.is_a?(Catalog::ArtifactImporter::Result) }
    assert_equal 1, results.count(&:replayed?)
    assert_equal 1, SyncRun.where(status: "succeeded").count
    assert_equal 3, SupplierObservation.count
  end

  test "concurrent different artifacts at one capture time produce one success and one conflict" do
    different = fixture_json(:product)
    different["response"]["requestId"] = "different-at-same-second"
    results = concurrently(fixture_bytes(:product), JSON.generate(different))

    assert_equal 1, results.count { |result| result.is_a?(Catalog::ArtifactImporter::Result) }
    error = results.find { |result| result.is_a?(Catalog::ArtifactImporter::Error) }
    assert_equal :temporal_conflict, error.code
    assert_equal 1, SyncRun.where(status: "succeeded").count
    assert_equal 1, SyncRun.where(status: "failed", error_code: "temporal_conflict").count
    assert_equal 3, SupplierObservation.count
  end

  test "country conflict rolls back the whole import and leaves a sanitized failed run" do
    import_product
    @importer.call(supplier: @supplier, operation: :inventory,
      artifact_bytes: fixture_bytes(:inventory), received_at: RECEIVED_AT)
    conflict = fixture_json(:inventory)
    conflict["observed_at"] = "2026-09-20T00:00:02Z"
    conflict["response"]["requestId"] = "country-conflict"
    conflict["response"]["data"][0]["countryCode"] = "US"
    before_catalog = catalog_snapshot

    assert_error(:warehouse_country_conflict) do
      @importer.call(supplier: @supplier, operation: :inventory,
        artifact_bytes: JSON.generate(conflict), received_at: RECEIVED_AT + 2.seconds)
    end
    assert_equal before_catalog, catalog_snapshot
    failed = SyncRun.order(:id).last
    assert_equal "failed", failed.status
    assert_equal 0, failed.seen_count
    assert_equal 0, failed.created_count
    assert_equal 0, failed.updated_count
    assert_equal 1, failed.error_count
    assert_equal "warehouse_country_conflict", failed.error_code
    assert_empty failed.sync_checkpoints
  end

  test "result and errors do not serialize payloads" do
    result = import_product
    serialized = [ result.inspect, result.to_s, result.as_json.to_json ]
    serialized.each do |value|
      refute_includes value, "Stacking storage bin"
      refute_includes value, "fixture-product-1"
    end
    assert_raises(TypeError) { Marshal.dump(result) }
    assert_raises(TypeError) { result.to_yaml }

    error = assert_raises(Catalog::ArtifactImporter::Error) do
      @importer.call(supplier: @supplier, operation: :product,
        artifact_bytes: "secret payload", received_at: RECEIVED_AT)
    end
    assert_equal "Catalog artifact import: invalid_artifact", error.message
    refute_includes error.inspect, "secret payload"
  end

  test "artifact content is filtered from model inspection and SQL logs" do
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io, level: Logger::DEBUG)
    with_sql_logger(logger) { import_product }

    refute_includes io.string, "Stacking storage bin"
    refute_includes io.string, "fixture-product-1"
    observation = SupplierObservation.first
    refute_includes observation.inspect, "Stacking storage bin"
    assert_includes observation.inspect, "[FILTERED]"
    assert_equal Logger::DEBUG, logger.level
  end


  test "unsupported debug logger fails closed before any row or sequence write" do
    unsupported_logger = Object.new
    unsupported_logger.define_singleton_method(:level) { Logger::DEBUG }
    before = durable_snapshot

    with_sql_logger(unsupported_logger) { assert_error(:unsafe_sql_logger) { import_product } }
    assert_equal before, durable_snapshot
  end

  test "standard Ruby debug logger never receives artifact or provider request content" do
    io = StringIO.new
    logger = Logger.new(io, level: Logger::DEBUG)

    with_sql_logger(logger) do
      if logger.respond_to?(:silence)
        import_product
      else
        assert_error(:unsafe_sql_logger) { import_product }
      end
    end
    refute_includes io.string, "Stacking storage bin"
    refute_includes io.string, "fixture-product-1"
    assert_equal Logger::DEBUG, logger.level
  end

  private
    def import_product(supplier: @supplier)
      @importer.call(supplier:, operation: :product,
        artifact_bytes: fixture_bytes(:product), received_at: RECEIVED_AT)
    end

    def validated(operation)
      Integrations::Cj::RecordArtifactValidator.new.read(operation:,
        artifact_bytes: fixture_bytes(operation))
    end

    def fixture_bytes(operation)
      Rails.root.join("test/fixtures/files/cj/v1/#{operation}.json").binread
    end

    def fixture_json(operation)
      JSON.parse(fixture_bytes(operation))
    end

    def assert_error(code, &block)
      error = assert_raises(Catalog::ArtifactImporter::Error, &block)
      assert_equal code, error.code
      error
    end

    def tables
      %w[sync_checkpoints sync_runs inventory_observations price_observations supplier_observations
        supplier_warehouses supplier_variants supplier_products product_variants products suppliers]
    end

    def catalog_snapshot
      (tables - %w[sync_runs sync_checkpoints]).to_h do |table|
        [ table, ApplicationRecord.connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ]
      end
    end

    def durable_snapshot
      data = tables.to_h do |table|
        [ table, ApplicationRecord.connection.select_all("SELECT * FROM #{table} ORDER BY id").to_a ]
      end
      sequences = tables.to_h do |table|
        name = "#{table}_id_seq"
        [ name, ApplicationRecord.connection.select_one("SELECT last_value, is_called FROM #{name}") ]
      end
      [ data, sequences ]
    end

    def clean_catalog!
      connection = ApplicationRecord.connection
      connection.disable_referential_integrity do
        tables.each { |table| connection.execute("TRUNCATE TABLE #{table} RESTART IDENTITY CASCADE") }
      end
    end

    def create_manual_stock_observation!(observed_at:, status:)
      SupplierObservation.create!(supplier: @supplier, resource_kind: "stock",
        external_resource_id: "00005678", provider_request_id: "manual-#{status}",
        endpoint_key: "product/stock/queryByVid", adapter_version: "1", payload_schema_version: 1,
        payload_json: { "evidence" => status }, payload_sha256: Digest::SHA256.digest("manual-#{status}"),
        observed_at:, received_at: observed_at, normalization_status: status,
        normalization_error_code: ("manual_failure" if status == "failed"), purge_after: observed_at + 30.days)
    end

    def create_uncheckpointed_success_for!(observation)
      hex = observation.payload_sha256.unpack1("H*")
      SyncRun.create!(supplier: @supplier, mode: "fixture", resource_kind: "inventory",
        scope_key: "catalog-import:v1:inventory:#{hex}",
        scope_json: { "operation" => "inventory", "external_resource_id" => "00005678",
          "artifact_sha256" => hex }, scope_schema_version: 1, adapter_version: "1", status: "succeeded",
        points_consumed: 0, seen_count: 1, created_count: 0, updated_count: 1, error_count: 0,
        started_at: observation.received_at, completed_at: observation.received_at)
    end

    def with_sql_logger(logger)
      connection = ApplicationRecord.connection
      prior_logger = connection.logger
      connection.instance_variable_set(:@logger, logger)
      yield
    ensure
      connection&.instance_variable_set(:@logger, prior_logger)
    end

    def concurrently(*artifacts)
      ready = Queue.new
      release = Queue.new
      threads = artifacts.map do |artifact|
        Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            ready << true
            release.pop
            begin
              Catalog::ArtifactImporter.new.call(supplier: Supplier.find(@supplier.id), operation: :product,
                artifact_bytes: artifact, received_at: RECEIVED_AT)
            rescue Catalog::ArtifactImporter::Error => error
              error
            end
          end
        end
      end
      artifacts.size.times { ready.pop }
      artifacts.size.times { release << true }
      threads.map(&:value)
    end
end
