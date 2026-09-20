class ProductsController < ApplicationController
  PAGE_SIZE = 12
  CONTROL_CHAR_PATTERN = /[\u0000-\u001f\u007f]/
  ERROR_COPY = {
    bad_request: [ "Catalog page unavailable", "Check the catalog link and try again." ],
    not_found: [ "Sample product not found", "This product is not in the current sample catalog." ],
    service_unavailable: [ "Sample catalog unavailable", "Please try browsing again later." ]
  }.freeze

  def self.build_product_reader(environment: Rails.env)
    unless environment.local?
      raise Catalog::ProductReader::Error.new(:source_unavailable, retryable: true), cause: nil
    end

    Catalog::FixtureProductReader.new
  end

  def index
    cursor = params[:cursor]
    raise Catalog::ProductReader::Error.new(:invalid_input) unless cursor.nil? || cursor.is_a?(String)

    @query = sanitized_search_query(params[:q])

    @page =
      if @query
        result = Search::CatalogSearch.new(product_reader: product_reader).call(query: @query, limit: PAGE_SIZE)
        Catalog::ProductReader::Page.new(items: result.items, next_cursor: nil)
      else
        product_reader.list(limit: PAGE_SIZE, cursor:)
      end
  rescue Catalog::ProductReader::Error => error
    render_catalog_error(error.code == :invalid_input ? :bad_request : :service_unavailable)
  end

  def show
    @product = product_reader.detail(id: params[:id])
  rescue Catalog::ProductReader::Error => error
    status = %i[invalid_input not_found].include?(error.code) ? :not_found : :service_unavailable
    render_catalog_error(status)
  end

  private
    def product_reader
      @product_reader ||= self.class.build_product_reader
    end

    def render_catalog_error(status)
      @error_title, @error_message = ERROR_COPY.fetch(status)
      render :error, status:
    end

    # Shopper search text is untrusted: control characters are stripped, the
    # value is bounded to Search::CatalogSearch::MAX_QUERY_BYTES, and a blank
    # or whitespace-only query is treated as no query at all rather than an
    # error. The result is only ever bound as a query parameter downstream
    # (Search::LexicalRetrieval) and is HTML-escaped by ERB wherever it is
    # echoed back into the page.
    def sanitized_search_query(raw)
      return nil unless raw.is_a?(String)

      scrubbed = raw.scrub("").gsub(CONTROL_CHAR_PATTERN, "")
      bounded =
        if scrubbed.bytesize > Search::CatalogSearch::MAX_QUERY_BYTES
          scrubbed.byteslice(0, Search::CatalogSearch::MAX_QUERY_BYTES).scrub("")
        else
          scrubbed
        end

      bounded.strip.presence
    end
end
