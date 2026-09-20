class HomeController < ApplicationController
  # A small proof-of-catalog slice for the home page, not a paginated
  # listing -- keep it well inside Catalog::ProductReader::MAX_LIMIT.
  PRODUCT_LIMIT = 6

  def show
    @catalog_page = catalog_reader.list(limit: PRODUCT_LIMIT)
  rescue Catalog::ProductReader::Error
    @catalog_page = Catalog::ProductReader::Page.new(items: [], next_cursor: nil)
    @catalog_unavailable = true
  end

  private
    # Reuses ProductsController's own reader selection (environment-gated,
    # fixture-only outside local dev/test) instead of duplicating or
    # hardcoding it here.
    def catalog_reader
      ProductsController.build_product_reader
    end
end
