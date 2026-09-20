class ProductsController < ApplicationController
  PAGE_SIZE = 12
  ERROR_COPY = {
    bad_request: [ "Catalog page unavailable", "Check the catalog link and try again." ],
    not_found: [ "Sample product not found", "This product is not in the current sample catalog." ],
    service_unavailable: [ "Sample catalog unavailable", "Please try browsing again later." ]
  }.freeze

  def self.build_product_reader(environment: Rails.env)
    return Catalog::FixtureProductReader.new if environment.local?
    return Catalog::DatabaseProductReader.new if environment.staging? || environment.production?

    raise Catalog::ProductReader::Error.new(:source_unavailable, retryable: true), cause: nil
  end

  def index
    cursor = params[:cursor]
    raise Catalog::ProductReader::Error.new(:invalid_input) unless cursor.nil? || cursor.is_a?(String)

    @page = product_reader.list(limit: PAGE_SIZE, cursor:)
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
end
