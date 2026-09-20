module Catalog
  # CAT-SYNC-01. Connects the record-mode CJ adapter to the offline artifact
  # pipeline: discover product ids, capture the untouched response bytes,
  # validate them as a v1 record artifact, and import them.
  #
  # Every provider call goes through Integrations::Cj::Adapter, which admits it
  # through the shared Governor/PointsBudget first. This class never talks to a
  # transport, never holds a credential, never chooses a mode, and never
  # reimplements or widens the budget: a refusal simply propagates and stops the
  # run.
  #
  # Supplier bytes stay untrusted all the way through. Nothing reaches
  # Catalog::ArtifactImporter that Integrations::Cj::RecordArtifactValidator has
  # not just re-parsed, shape-checked, and re-encoded into the canonical v1
  # envelope -- fetching the bytes ourselves buys them no trust.
  #
  # Bounding is explicit and caller-supplied: +max_products+ caps discovery and
  # therefore the whole run, and pagination is driven here one page per adapter
  # call, never inside the adapter. Nothing loops unbounded.
  #
  # Idempotency is the importer's: re-running an identical capture matches the
  # artifact-sha256 scope key of the earlier successful SyncRun and replays as a
  # no-op. This class adds no replay logic of its own; it only counts a replay
  # as "skipped".
  class SupplierCapture
    MAX_PRODUCTS = 100
    MAX_PAGE_SIZE = 50
    DEFAULT_PAGE_SIZE = 20
    DEFAULT_MAX_VARIANTS_PER_PRODUCT = 25
    POINTS = Integrations::Cj::Adapter::POINTS

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super("Catalog supplier capture: #{code}")
      end
    end

    # Holds the most recent raw response per operation. Deliberately tiny and
    # in-memory: it owns no path, no IO, and no retention. The adapter writes to
    # it; the capture run reads exactly one entry back per call it made and
    # consumes it, so a stale body can never be imported for a later request.
    class RawSink
      def initialize
        @captures = {}
      end

      # Time#iso8601 produces a US-ASCII string while
      # RecordArtifactValidator requires UTF-8. That timestamp is ours, not
      # supplier data, so re-tagging it here is a representation fix and not a
      # trust decision; the response body is left exactly as received.
      def call(operation:, request:, body:, observed_at:)
        @captures[operation] = { request: request, body: body,
          observed_at: observed_at.to_s.dup.force_encoding(Encoding::UTF_8) }
        nil
      end

      # Consumes the capture for +operation+ and verifies it belongs to exactly
      # the request we just issued.
      def take!(operation:, request:)
        entry = @captures.delete(operation)
        raise Error.new(:missing_capture) unless entry.is_a?(Hash) && entry.fetch(:request) == request

        entry
      end

      def discard(operation)
        @captures.delete(operation)
        nil
      end
    end

    Summary = Data.define(:products_discovered, :products_captured, :products_imported, :products_skipped,
      :variants_captured, :variants_imported, :variants_skipped, :points_consumed, :calls, :dry_run) do
      def dry_run?
        dry_run
      end

      def as_json(*)
        to_h.transform_keys(&:to_s).merge("calls" => calls.transform_keys(&:to_s))
      end

      def to_s
        as_json.map { |key, value| "#{key}=#{value.is_a?(Hash) ? value.inspect : value}" }.join(" ")
      end
    end

    # Convenience constructor for trusted server-side callers (the catalog:sync
    # rake task): builds the sink, hands it to the caller's adapter factory, and
    # wires both into one capture. The adapter -- and therefore the mode
    # decision and the credential -- stays entirely the caller's business.
    def self.build(supplier:, **options)
      sink = RawSink.new
      new(supplier: supplier, adapter: yield(sink), sink: sink, **options)
    end

    def initialize(supplier:, adapter:, sink:, importer: ArtifactImporter.new,
      validator: Integrations::Cj::RecordArtifactValidator.new, clock: -> { Time.current })
      unless supplier.instance_of?(Supplier) && supplier.persisted? && sink.instance_of?(RawSink) &&
          adapter.respond_to?(:mode) && importer.instance_of?(ArtifactImporter) &&
          validator.instance_of?(Integrations::Cj::RecordArtifactValidator) && clock.respond_to?(:call)
        raise Error.new(:invalid_input)
      end

      @supplier = supplier
      @adapter = adapter
      @sink = sink
      @importer = importer
      @validator = validator
      @clock = clock
    end

    def call(max_products:, page_size: DEFAULT_PAGE_SIZE, category: nil, keyword: nil,
      max_variants_per_product: DEFAULT_MAX_VARIANTS_PER_PRODUCT, dry_run: false)
      validate!(max_products:, page_size:, category:, keyword:, max_variants_per_product:, dry_run:)
      raise Error.new(:unsupported_mode) unless @adapter.mode == :record

      @calls = { product_list: 0, product: 0, inventory: 0 }
      counts = Hash.new(0)

      product_ids = discover(max_products:, page_size:, category:, keyword:)
      product_ids.each do |product_id|
        variant_ids = capture_product(product_id, counts, dry_run:, limit: max_variants_per_product)
        next if dry_run

        variant_ids.each { |variant_id| capture_inventory(variant_id, counts) }
      end

      Summary.new(products_discovered: product_ids.size, products_captured: counts[:products_captured],
        products_imported: counts[:products_imported], products_skipped: counts[:products_skipped],
        variants_captured: counts[:variants_captured], variants_imported: counts[:variants_imported],
        variants_skipped: counts[:variants_skipped], points_consumed: points_consumed,
        calls: @calls.freeze, dry_run:).freeze
    rescue Integrations::Cj::Error => error
      raise Error.new(error.code), cause: nil
    rescue ArtifactImporter::Error => error
      raise Error.new(error.code), cause: nil
    end

    private
      # One explicit page per adapter call. The page budget is derived from the
      # caller's product bound, so discovery cannot outlive it even if the
      # provider keeps reporting more results.
      def discover(max_products:, page_size:, category:, keyword:)
        ids = []
        max_pages = (max_products.to_f / page_size).ceil

        1.upto(max_pages) do |page|
          @calls[:product_list] += 1
          page_result = @adapter.product_list(page: page, page_size: page_size, category: category,
            keyword: keyword)
          @sink.discard(:product_list)
          summaries = page_result.value.products
          summaries.each { |summary| ids << summary.external_id }
          ids.uniq!
          break if ids.size >= max_products || summaries.empty? || !page_result.value.has_more
        end

        ids.first(max_products)
      end

      def capture_product(product_id, counts, dry_run:, limit:)
        @calls[:product] += 1
        @adapter.product(product_id: product_id)
        validated = validate_capture(:product, { "product_id" => product_id })
        counts[:products_captured] += 1
        result = import(:product, validated, dry_run:)
        counts[result.replayed? ? :products_skipped : :products_imported] += 1
        validated.normalized.value.variants.map(&:external_id).first(limit)
      end

      def capture_inventory(variant_id, counts)
        @calls[:inventory] += 1
        @adapter.inventory(variant_id: variant_id)
        validated = validate_capture(:inventory, { "variant_id" => variant_id })
        counts[:variants_captured] += 1
        result = import(:inventory, validated, dry_run: false)
        counts[result.replayed? ? :variants_skipped : :variants_imported] += 1
      end

      # The untrusted-bytes boundary: the validator re-parses the captured body
      # and re-encodes the canonical v1 envelope. A tampered or malformed body
      # raises here, before the importer ever sees it.
      def validate_capture(operation, request)
        entry = @sink.take!(operation: operation, request: request)
        @validator.call(operation: operation, request: entry.fetch(:request),
          raw_body: entry.fetch(:body), observed_at: entry.fetch(:observed_at))
      end

      def import(operation, validated, dry_run:)
        @importer.call(supplier: @supplier, operation: operation,
          artifact_bytes: validated.artifact_bytes, received_at: received_at, dry_run: dry_run)
      end

      def received_at
        time = @clock.call
        raise Error.new(:invalid_input) unless time.is_a?(Time) || time.is_a?(ActiveSupport::TimeWithZone)

        time.utc
      end

      # Exact for the calls this run issued, using the adapter's own per-call
      # estimates. It excludes the adapter's internal access-token fetches
      # (Adapter::AUTH_POINTS, normally one per run), which this class does not
      # initiate and cannot observe.
      def points_consumed
        @calls.sum { |operation, count| POINTS.fetch(operation) * count }
      end

      def validate!(max_products:, page_size:, category:, keyword:, max_variants_per_product:, dry_run:)
        unless max_products.instance_of?(Integer) && max_products.between?(1, MAX_PRODUCTS) &&
            page_size.instance_of?(Integer) && page_size.between?(1, MAX_PAGE_SIZE) &&
            max_variants_per_product.instance_of?(Integer) &&
            max_variants_per_product.between?(1, DEFAULT_MAX_VARIANTS_PER_PRODUCT) &&
            [ true, false ].include?(dry_run) &&
            (category.is_a?(String) || keyword.is_a?(String))
          raise Error.new(:invalid_input)
        end
      end
  end
end
