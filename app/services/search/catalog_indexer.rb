require "digest"

module Search
  # Indexes catalog products, read only through Catalog::ProductReader, into the
  # search_documents lexical index (DB-05). It never reads a raw supplier payload:
  # only the sanitized reader projection (title/description) is normalized and hashed.
  #
  # Indexing is idempotent and supersede-based: a subject/kind/locale keeps at most one
  # active document. Re-indexing identical content is a no-op; changed content marks the
  # prior active row superseded and inserts a new active row with a content-derived
  # source_version, so the (subject, kind, locale, source_version) unique key never
  # collides across an indexing run.
  class CatalogIndexer
    DOCUMENT_KIND = "listing"
    LOCALE = "en"

    # CAT-DB-READER-01 fix #5: catalog:sync's summary used to print `processed`
    # (products attempted) as if it meant "now searchable", so a deployment where
    # every product came back :skipped (the exact defect this fix addresses) still
    # reported success. `indexed` is the subset that is actually active with new
    # content after this run -- a :skipped or :unchanged row contributed nothing new.
    Result = Data.define(:processed, :created, :superseded, :unchanged, :skipped) do
      def indexed
        created + superseded
      end
    end

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super("Search catalog indexer: #{code}")
      end
    end

    def initialize(product_reader: Catalog::ReaderSelection.call)
      @product_reader = product_reader
    end

    def call(page_limit: Catalog::ProductReader::MAX_LIMIT)
      unless page_limit.is_a?(Integer) && page_limit.between?(1, Catalog::ProductReader::MAX_LIMIT)
        raise Error.new(:invalid_input)
      end

      counts = { created: 0, superseded: 0, unchanged: 0, skipped: 0 }
      processed = 0
      cursor = nil

      loop do
        page = @product_reader.list(limit: page_limit, cursor: cursor)
        page.items.each do |product|
          processed += 1
          counts[index_product(product)] += 1
        end
        cursor = page.next_cursor
        break if cursor.nil?
      end

      Result.new(processed:, **counts)
    rescue Catalog::ProductReader::Error => error
      raise Error.new(error.code)
    end

    private
      def index_product(product)
        local_product_id = resolve_local_product_id(product)
        return :skipped if local_product_id.nil?

        normalized_text = normalize_text(product)
        return :skipped if normalized_text.empty?

        content_hash = Digest::SHA256.digest(normalized_text)

        ApplicationRecord.transaction do
          existing = SearchDocument.lock.find_by(
            product_id: local_product_id, product_variant_id: nil,
            document_kind: DOCUMENT_KIND, locale: LOCALE, status: "active"
          )

          next :unchanged if existing && existing.content_hash == content_hash

          existing&.update!(status: "superseded")
          SearchDocument.create!(
            product_id: local_product_id, product_variant_id: nil,
            document_kind: DOCUMENT_KIND, locale: LOCALE,
            normalized_text: normalized_text, content_hash: content_hash,
            source_version: "content:#{content_hash.unpack1('H*')}",
            status: "active", generated_at: Time.current
          )
          existing ? :superseded : :created
        end
      end

      # CAT-DB-READER-01: SupplierProduct#external_product_id is the right lookup
      # only for :supplier_external readers (product.id is CJ's own id there). Under
      # :local_public_id (Catalog::DatabaseProductReader) product.id already IS
      # Product#public_id -- the reader read that row to build the DTO -- so no
      # SupplierProduct hop is needed to know the product exists; going through it
      # anyway is exactly why every real product came back :skipped despite a
      # successful catalog:sync.
      def resolve_local_product_id(product)
        if local_public_id_scheme?
          ::Product.find_by(public_id: product.id)&.id
        else
          SupplierProduct.order(:supplier_id).find_by(external_product_id: product.id)&.product_id
        end
      end

      # Own-class check only (not inherited): a reader that never declares ID_SCHEME
      # (e.g. a bare test double) is treated as :supplier_external, matching this
      # indexer's behavior before CAT-DB-READER-01 rather than raising on it.
      def local_public_id_scheme?
        klass = @product_reader.class
        klass.const_defined?(:ID_SCHEME, false) && klass::ID_SCHEME == :local_public_id
      end

      # Only the reader's already-sanitized title/description fields are used, and they
      # are sanitized again here as defense in depth. Supplier text is data, never a
      # system/model instruction, and no HTML/markup survives into the index.
      def normalize_text(product)
        parts = [ product.title, product.description ].compact.map do |text|
          ActionView::Base.full_sanitizer.sanitize(text).to_s
        end
        parts.join("\n\n").squish
      end
  end
end
