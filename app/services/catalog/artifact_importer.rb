require "digest"
require "json"
require "uri"

module Catalog
  class ArtifactImporter
    OPERATIONS = %i[product inventory].freeze
    MAX_DUPLICATED_PAYLOAD_BYTES = 8_388_608
    PURGE_RETENTION = 30.days
    SCOPE_VERSION = 1
    CHECKPOINT_VERSION = 1

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super("Catalog artifact import: #{code}")
      end
    end

    Result = Data.define(:operation, :sync_run_id, :counts, :replayed, :dry_run) do
      def replayed?
        replayed
      end

      def dry_run?
        dry_run
      end

      def inspect
        "#<#{self.class.name} operation=#{operation.inspect} sync_run_id=#{sync_run_id.inspect} " \
          "counts=#{counts.inspect} replayed=#{replayed} dry_run=#{dry_run}>"
      end

      alias_method :to_s, :inspect

      def as_json(*)
        { "operation" => operation.to_s, "sync_run_id" => sync_run_id,
          "counts" => counts.transform_keys(&:to_s), "replayed" => replayed, "dry_run" => dry_run }
      end

      def to_json(...)
        as_json.to_json(...)
      end

      def encode_with(*)
        raise TypeError, "Catalog import result serialization is disabled"
      end

      def marshal_dump
        raise TypeError, "Catalog import result serialization is disabled"
      end
    end

    def initialize(validator: Integrations::Cj::RecordArtifactValidator.new)
      raise Error.new(:invalid_input) unless validator.instance_of?(Integrations::Cj::RecordArtifactValidator)

      @validator = validator
    end

    def call(supplier:, operation:, artifact_bytes:, received_at:, dry_run: false)
      validate_call!(supplier:, operation:, artifact_bytes:, received_at:, dry_run:)
      validated = read_artifact(operation:, artifact_bytes:)
      receipt_time = received_at.to_time.utc
      observed_at = validated.provenance.observed_at.utc
      raise Error.new(:future_artifact) if observed_at > receipt_time

      context = build_context(supplier:, operation:, validated:, received_at: receipt_time, dry_run:)
      result = nil

      without_sql_payload_logging do
        ApplicationRecord.transaction(requires_new: true) do
          supplier.lock!
          validate_locked_supplier!(context)
          replay = successful_replay(context)
          if replay
            result = result_for_run(replay, replayed: true, dry_run:)
            next
          end

          plan = operation == :product ? preflight_product(context) : preflight_inventory(context)
          enforce_payload_budget!(validated.artifact_bytes.bytesize, plan.fetch(:observation_copies))
          counts = plan.fetch(:counts).freeze

          if dry_run
            result = build_result(operation:, counts:, dry_run: true)
            next
          end

          operation == :product ? apply_product(context, plan) : apply_inventory(context, plan)
          run = create_success_run!(context, counts)
          result = result_for_run(run, replayed: false)
        end
      end

      result
    rescue Error => error
      persist_failure(context, error) if context && !dry_run && failure_record_allowed?(error)
      raise Error.new(error.code), cause: nil
    rescue ActiveRecord::ActiveRecordError
      error = Error.new(:persistence_failed)
      persist_failure(context, error) if context && !dry_run
      raise error, cause: nil
    end

    private
      Context = Data.define(:supplier, :operation, :validated, :received_at, :observed_at,
        :external_resource_id, :scope_key, :scope_json, :payload_json, :dry_run)

      def validate_call!(supplier:, operation:, artifact_bytes:, received_at:, dry_run:)
        unless supplier.instance_of?(Supplier) && supplier.persisted? && !supplier.destroyed? &&
            operation.instance_of?(Symbol) && OPERATIONS.include?(operation) &&
            artifact_bytes.instance_of?(String) && (received_at.is_a?(Time) || received_at.is_a?(ActiveSupport::TimeWithZone)) &&
            [ true, false ].include?(dry_run)
          code = operation.instance_of?(Symbol) && !OPERATIONS.include?(operation) ? :invalid_operation : :invalid_input
          raise Error.new(code)
        end
        raise Error.new(:supplier_mismatch) unless supplier.key == "cj"
      end

      def read_artifact(operation:, artifact_bytes:)
        @validator.read(operation:, artifact_bytes:)
      rescue Integrations::Cj::Error
        raise Error.new(:invalid_artifact), cause: nil
      end

      def build_context(supplier:, operation:, validated:, received_at:, dry_run:)
        provenance = validated.provenance
        raise Error.new(:supplier_mismatch) unless provenance.provider == :cj &&
          provenance.adapter_version == supplier.adapter_version

        external_resource_id = case operation
        when :product then validated.normalized.value.external_id
        when :inventory then validated.normalized.request.fetch("variant_id")
        end
        artifact_sha256 = validated.artifact_sha256
        scope_json = {
          "operation" => operation.to_s,
          "external_resource_id" => external_resource_id,
          "artifact_sha256" => artifact_sha256
        }.freeze
        Context.new(supplier:, operation:, validated:, received_at:,
          observed_at: provenance.observed_at.utc, external_resource_id:,
          scope_key: "catalog-import:v1:#{operation}:#{artifact_sha256}", scope_json:,
          payload_json: JSON.parse(validated.artifact_bytes), dry_run:)
      end

      def successful_replay(context)
        SyncRun.find_by(supplier: context.supplier, resource_kind: context.operation.to_s,
          scope_key: context.scope_key, status: "succeeded")
      end

      def validate_locked_supplier!(context)
        provenance = context.validated.provenance
        unless context.supplier.key == "cj" && context.supplier.adapter_version == provenance.adapter_version
          raise Error.new(:supplier_mismatch)
        end
      end

      def preflight_product(context)
        value = context.validated.normalized.value
        title = normalized_title(value.title)
        image_urls = validate_media_urls!(value.image_urls)
        variants = value.variants.map do |variant|
          ensure_decimal_measurements!(variant)
          { value: variant, title: variant_title(variant, title) }
        end

        supplier_product = SupplierProduct.find_by(supplier: context.supplier,
          external_product_id: value.external_id)
        validate_reference_time!(supplier_product, context)
        validate_subject_time!(supplier_product&.latest_observation, context)

        variant_plans = variants.map do |entry|
          variant = entry.fetch(:value)
          supplier_variant = SupplierVariant.find_by(supplier: context.supplier,
            external_variant_id: variant.external_id)
          if supplier_variant && supplier_product && supplier_variant.supplier_product_id != supplier_product.id
            raise Error.new(:supplier_association_conflict)
          end
          if supplier_variant && supplier_product.nil?
            raise Error.new(:supplier_association_conflict)
          end
          if supplier_variant && supplier_variant.product_variant.product_id != supplier_product.product_id
            raise Error.new(:supplier_association_conflict)
          end
          validate_reference_time!(supplier_variant, context)
          validate_subject_time!(supplier_variant&.latest_observation, context)
          entry.merge(supplier_variant:)
        end

        created = (supplier_product ? 0 : 1) + variant_plans.count { |entry| entry[:supplier_variant].nil? }
        updated = (supplier_product ? 1 : 0) + variant_plans.count { |entry| entry[:supplier_variant] }
        counts = count_hash(seen: 1 + variant_plans.size, created:, updated:)
        { value:, title:, supplier_product:, variants: variant_plans, image_urls:,
          observation_copies: 1 + variant_plans.size, counts: }
      end

      def preflight_inventory(context)
        rows = context.validated.normalized.value
        supplier_variant = SupplierVariant.includes(:product_variant, :supplier_product).find_by(
          supplier: context.supplier, external_variant_id: context.external_resource_id)
        supplier_product = supplier_variant&.supplier_product
        unless supplier_variant&.product_variant && supplier_product&.supplier_id == context.supplier.id &&
            supplier_variant.product_variant.product_id == supplier_product.product_id &&
            supplier_variant.latest_observation&.resource_kind == "variant" &&
            supplier_product.latest_observation&.resource_kind == "product"
          raise Error.new(:variant_not_imported)
        end

        validate_reference_time!(supplier_variant, context)
        latest_stock = latest_successful_stock_observation(context)
        validate_subject_time!(latest_stock, context)

        warehouses = rows.map do |row|
          warehouse = SupplierWarehouse.find_by(supplier: context.supplier,
            external_warehouse_id: row.warehouse_id)
          validate_reference_time!(warehouse, context)
          if warehouse&.country_code.present? && warehouse.country_code != row.country_code
            raise Error.new(:warehouse_country_conflict)
          end
          { value: row, warehouse: }
        end
        created = warehouses.count { |entry| entry[:warehouse].nil? }
        updated = (reference_timestamp_changed?(supplier_variant, context) ? 1 : 0) +
          warehouses.count { |entry| entry[:warehouse] && warehouse_changed?(entry, context) }
        { supplier_variant:, warehouses:, observation_copies: 1,
          counts: count_hash(seen: 1 + warehouses.size, created:, updated:) }
      end

      def validate_reference_time!(reference, context)
        return unless reference
        raise Error.new(:decreasing_receipt_time) if reference.last_seen_at > context.received_at
      end

      def validate_subject_time!(observation, context)
        return unless observation
        if observation.observed_at > context.observed_at
          raise Error.new(:stale_artifact)
        elsif observation.observed_at == context.observed_at &&
            observation.payload_sha256 != decoded_hash(context.validated.artifact_sha256)
          raise Error.new(:temporal_conflict)
        end
      end

      def latest_successful_stock_observation(context)
        SupplierObservation.joins(<<~SQL.squish).joins(<<~SQL.squish).
          INNER JOIN sync_runs ON
            sync_runs.supplier_id = supplier_observations.supplier_id AND
            sync_runs.resource_kind = 'inventory' AND
            sync_runs.status = 'succeeded' AND
            sync_runs.mode = 'fixture' AND
            sync_runs.scope_schema_version = 1 AND
            sync_runs.points_consumed = 0 AND
            sync_runs.error_count = 0 AND
            sync_runs.adapter_version = supplier_observations.adapter_version AND
            sync_runs.started_at = supplier_observations.received_at AND
            sync_runs.completed_at = supplier_observations.received_at AND
            sync_runs.scope_key = 'catalog-import:v1:inventory:' || encode(supplier_observations.payload_sha256, 'hex') AND
            sync_runs.scope_json = jsonb_build_object(
              'operation', 'inventory',
              'external_resource_id', supplier_observations.external_resource_id,
              'artifact_sha256', encode(supplier_observations.payload_sha256, 'hex')
            )
        SQL
          INNER JOIN sync_checkpoints ON
            sync_checkpoints.sync_run_id = sync_runs.id AND
            sync_checkpoints.checkpoint_key = 'artifact_applied' AND
            sync_checkpoints.cursor IS NULL AND
            sync_checkpoints.page_number IS NULL AND
            sync_checkpoints.state_schema_version = 1 AND
            sync_checkpoints.state_json = jsonb_build_object(
              'operation', 'inventory',
              'external_resource_id', supplier_observations.external_resource_id,
              'artifact_sha256', encode(supplier_observations.payload_sha256, 'hex'),
              'subject_count', sync_runs.seen_count,
              'status', 'applied'
            )
        SQL
          where(supplier: context.supplier, resource_kind: "stock",
            external_resource_id: context.external_resource_id, normalization_status: "normalized",
            endpoint_key: "product/stock/queryByVid", payload_schema_version: 1).
          where(<<~SQL.squish).
            NOT EXISTS (
              SELECT 1 FROM sync_checkpoints other_checkpoints
              WHERE other_checkpoints.sync_run_id = sync_runs.id
                AND other_checkpoints.id <> sync_checkpoints.id
            )
          SQL
          order(observed_at: :desc, id: :desc).first
      end

      def ensure_decimal_measurements!(variant)
        %i[weight length width height].each do |name|
          measurement = variant.public_send(name)
          next unless measurement
          value = measurement.value
          unless value.finite? && value >= 0 && value <= BigDecimal("9999999999.9999") &&
              (value * 10_000).frac.zero?
            raise Error.new(:decimal_not_representable)
          end
        end
      end

      # Supplier image URLs are untrusted input (CAT-MEDIA-01): re-validate
      # them here at persistence time against the same approved-host rule
      # Catalog::DatabaseProductReader enforces at read time, rather than
      # trusting that Integrations::Cj::Normalizer already filtered them. Any
      # URL that fails fails the whole import, exactly like every other
      # malformed-artifact rejection in this class (e.g. :blank_title,
      # :decimal_not_representable): a single bad image never causes a
      # partially-imported product, and it produces the same explicit,
      # auditable failure code as those checks instead of silently dropping
      # a picture and letting the rest of the import appear to succeed.
      def validate_media_urls!(urls)
        return [] if urls.nil?

        urls.each { |url| validate_media_url!(url) }
        urls
      end

      def validate_media_url!(url)
        unless url.is_a?(String) && url.encoding == Encoding::UTF_8 && url.valid_encoding? &&
            url.bytesize.between?(1, 2048)
          raise Error.new(:unsafe_media_url)
        end

        uri = URI.parse(url)
        unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.userinfo.nil? && uri.query.nil? &&
            uri.fragment.nil? && FixtureProductReader::APPROVED_MEDIA_HOSTS.include?(uri.host) &&
            uri.path.start_with?("/") && !uri.path.split("/").include?("..") && !uri.path.include?("%")
          raise Error.new(:unsafe_media_url)
        end
      rescue URI::InvalidURIError
        raise Error.new(:unsafe_media_url), cause: nil
      end

      # Reconciles catalog_media for this product to exactly the validated
      # image_urls from this artifact: existing rows are matched by
      # sanitized_url and updated in place (position/observed_at/the
      # supplier_observation pointer), new URLs are inserted, and rows for
      # URLs no longer present are removed. Re-importing identical bytes
      # never reaches this method at all (the exact-artifact replay check in
      # #call short-circuits first), so this only runs when the artifact
      # actually changed, and it converges rather than accumulating rows.
      def sync_product_images!(context, product, observation, image_urls)
        existing = CatalogMedia.where(product_id: product.id, kind: "image").index_by(&:sanitized_url)

        image_urls.each_with_index do |url, position|
          media = existing.delete(url) || CatalogMedia.new(product_id: product.id, kind: "image")
          media.assign_attributes(position:, status: "active", observed_at: context.observed_at,
            supplier_observation_id: observation.id, sanitized_url: url)
          media.save!
        end

        existing.each_value(&:destroy!)
      end

      # A variant needs a title the catalog can display, and CJ does not
      # reliably give one: seven of twelve live pet-category products returned
      # variantNameEn: "" on every variant. Rather than reject those products or
      # invent a name, fall back through the supplier's own values in order of
      # specificity -- the English variant name, then variantKey, the label CJ
      # uses for the option itself ("Yellow-Small size"), then the product's
      # title, which is literally what CJ puts in variantNameEn on the products
      # that do populate it. Every candidate is supplier-authored; nothing here
      # is derived or guessed. If all three are blank the import still fails.
      def variant_title(variant, product_title)
        candidate = [ variant.title, variant.option_label ].find { |value| value&.strip.present? }
        candidate.nil? ? product_title : normalized_title(candidate)
      end

      def normalized_title(value)
        title = value&.strip
        raise Error.new(:blank_title) if title.blank?
        title
      end

      def enforce_payload_budget!(artifact_size, observation_copies)
        if artifact_size * observation_copies > MAX_DUPLICATED_PAYLOAD_BYTES
          raise Error.new(:artifact_budget_exceeded)
        end
      end

      def warehouse_changed?(entry, context)
        warehouse = entry.fetch(:warehouse)
        value = entry.fetch(:value)
        reference_timestamp_changed?(warehouse, context) || warehouse.country_code != value.country_code
      end

      def reference_timestamp_changed?(reference, context)
        reference.last_seen_at != context.received_at ||
          (reference.respond_to?(:last_synced_at) && reference.last_synced_at != context.received_at)
      end

      def apply_product(context, plan)
        value = plan.fetch(:value)
        product_reference = plan.fetch(:supplier_product)
        product = if product_reference
          product_reference.product.tap do |record|
            record.update!(title: plan.fetch(:title), description: value.description || "")
          end
        else
          Product.create!(title: plan.fetch(:title), description: value.description || "", status: "draft")
        end

        product_reference ||= SupplierProduct.new(supplier: context.supplier, product:)
        product_reference.assign_attributes(external_product_id: value.external_id, external_sku: value.sku,
          status: product_reference.status.presence || "observed",
          first_seen_at: product_reference.first_seen_at || context.received_at,
          last_seen_at: context.received_at, last_synced_at: context.received_at,
          adapter_version: context.validated.provenance.adapter_version)
        product_reference.save!
        product_observation = create_observation!(context, resource_kind: "product",
          external_resource_id: value.external_id)
        product_reference.update!(latest_observation: product_observation)
        sync_product_images!(context, product, product_observation, plan.fetch(:image_urls))

        plan.fetch(:variants).each do |entry|
          apply_variant(context, product_reference, product, entry)
        end
      end

      def apply_variant(context, product_reference, product, entry)
        value = entry.fetch(:value)
        reference = entry.fetch(:supplier_variant)
        variant = reference&.product_variant || ProductVariant.new(product:)
        variant.assign_attributes(variant_attributes(value, entry.fetch(:title)))
        variant.status ||= "active"
        variant.save!

        reference ||= SupplierVariant.new(supplier: context.supplier, product_variant: variant,
          supplier_product: product_reference)
        reference.assign_attributes(external_variant_id: value.external_id,
          external_variant_sku: value.sku, status: reference.status.presence || "observed",
          first_seen_at: reference.first_seen_at || context.received_at,
          last_seen_at: context.received_at, last_synced_at: context.received_at,
          **supplier_measurement_attributes(value))
        reference.save!
        observation = create_observation!(context, resource_kind: "variant",
          external_resource_id: value.external_id)
        reference.update!(latest_observation: observation)
        return unless value.price

        PriceObservation.create!(supplier: context.supplier, supplier_variant: reference,
          supplier_observation: observation, amount_minor: value.price.amount_minor,
          currency: value.price.currency, price_kind: "supplier_sell", observed_at: context.observed_at)
      end

      def apply_inventory(context, plan)
        variant = plan.fetch(:supplier_variant)
        variant.update!(last_seen_at: context.received_at, last_synced_at: context.received_at)
        observation = create_observation!(context, resource_kind: "stock",
          external_resource_id: context.external_resource_id)

        plan.fetch(:warehouses).each do |entry|
          value = entry.fetch(:value)
          warehouse = entry.fetch(:warehouse) || SupplierWarehouse.new(supplier: context.supplier)
          warehouse.assign_attributes(external_warehouse_id: value.warehouse_id,
            country_code: value.country_code, status: warehouse.status.presence || "observed",
            first_seen_at: warehouse.first_seen_at || context.received_at,
            last_seen_at: context.received_at)
          warehouse.save!
          quantities = {
            total_quantity: value.total_quantity,
            cj_quantity: value.cj_quantity,
            factory_quantity: value.factory_quantity
          }
          next if quantities.values.all?(&:nil?)

          InventoryObservation.create!(supplier: context.supplier, supplier_variant: variant,
            supplier_warehouse: warehouse, supplier_observation: observation,
            observed_at: context.observed_at, **quantities)
        end
      end

      def create_observation!(context, resource_kind:, external_resource_id:)
        provenance = context.validated.provenance
        SupplierObservation.create!(supplier: context.supplier, resource_kind:, external_resource_id:,
          provider_request_id: provenance.request_id, endpoint_key: provenance.endpoint_key,
          adapter_version: provenance.adapter_version, payload_schema_version: provenance.payload_version.to_i,
          payload_json: context.payload_json, payload_sha256: decoded_hash(context.validated.artifact_sha256),
          observed_at: context.observed_at, received_at: context.received_at,
          normalization_status: "normalized", purge_after: context.received_at + PURGE_RETENTION)
      end

      def create_success_run!(context, counts)
        run = SyncRun.create!(supplier: context.supplier, mode: "fixture",
          resource_kind: context.operation.to_s, scope_key: context.scope_key,
          scope_json: context.scope_json, scope_schema_version: SCOPE_VERSION,
          adapter_version: context.validated.provenance.adapter_version, status: "succeeded",
          points_consumed: 0, seen_count: counts.fetch(:seen), created_count: counts.fetch(:created),
          updated_count: counts.fetch(:updated), error_count: 0,
          started_at: context.received_at, completed_at: context.received_at)
        run.sync_checkpoints.create!(checkpoint_key: "artifact_applied", cursor: nil, page_number: nil,
          state_schema_version: CHECKPOINT_VERSION,
          state_json: context.scope_json.merge("subject_count" => counts.fetch(:seen), "status" => "applied"))
        run
      end

      def persist_failure(context, error)
        ApplicationRecord.transaction(requires_new: true) do
          context.supplier.lock!
          unless successful_replay(context)
            SyncRun.create!(supplier: context.supplier, mode: "fixture",
              resource_kind: context.operation.to_s, scope_key: context.scope_key,
              scope_json: context.scope_json, scope_schema_version: SCOPE_VERSION,
              adapter_version: context.validated.provenance.adapter_version, status: "failed",
              points_consumed: 0, seen_count: 0, created_count: 0, updated_count: 0,
              error_count: 1, started_at: context.received_at, completed_at: context.received_at,
              error_code: error.code.to_s)
          end
        end
      rescue ActiveRecord::ActiveRecordError
        nil
      end

      def failure_record_allowed?(error)
        !%i[
          variant_not_imported supplier_mismatch invalid_input invalid_operation invalid_artifact unsafe_sql_logger
        ].include?(error.code)
      end

      def result_for_run(run, replayed:, dry_run: false)
        build_result(operation: run.resource_kind.to_sym, sync_run_id: run.id,
          counts: count_hash(seen: run.seen_count, created: run.created_count,
            updated: run.updated_count, errors: run.error_count), replayed:, dry_run:)
      end

      def build_result(operation:, counts:, sync_run_id: nil, replayed: false, dry_run: false)
        Result.new(operation:, sync_run_id:, counts: counts.freeze, replayed:, dry_run:).freeze
      end

      def count_hash(seen:, created:, updated:, errors: 0)
        { seen:, created:, updated:, errors: }
      end

      def variant_attributes(value, title)
        { title:, canonical_sku: nil, option_summary: {}, option_schema_version: 1,
          status: nil }.merge(supplier_measurement_attributes(value)).tap { |attributes| attributes.delete(:status) }
      end

      def supplier_measurement_attributes(value)
        weight = value.weight
        dimensions = [ value.length, value.width, value.height ]
        {
          weight_value: weight&.value, weight_unit: weight&.unit,
          length_value: value.length&.value, width_value: value.width&.value,
          height_value: value.height&.value,
          dimension_unit: dimensions.any? ? dimensions.compact.first&.unit : nil
        }
      end

      def decoded_hash(value)
        [ value ].pack("H*")
      end

      def without_sql_payload_logging(&block)
        logger = ActiveRecord::Base.logger
        return yield unless logger
        unless logger.respond_to?(:silence) && (!logger.respond_to?(:silencer) || logger.silencer)
          raise Error.new(:unsafe_sql_logger)
        end

        logger.silence(Logger::ERROR, &block)
      end
  end
end
