require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "renders the accessible public application shell" do
    get root_path

    assert_response :success
    assert_select "title", "Nudge"
    assert_select "a[href='#main-content']", text: /Skip to content/
    assert_select "header nav[aria-label='Primary navigation']"
    assert_select "main#main-content[tabindex='-1']"
    assert_select "footer"
    assert_select "h1", count: 1
  end

  test "uses mobile-safe responsive layout and accessible controls" do
    get root_path

    assert_select "main.min-w-0"
    assert_select ".grid.grid-cols-1"
    assert_select "a.min-h-11"
    assert_select "a[class*='focus-visible:']"
  end

  test "is a working shopping surface: search field, voice launcher, and real catalog items" do
    get root_path

    assert_response :success
    assert_select "input#q"
    assert_select "form[action='#{products_path}'][method='get']"
    assert_select "[data-voice-launcher][data-voice-state='idle']"
    assert_select "article", count: HomeController::PRODUCT_LIMIT
    assert_select "a[href='#{product_path('00001234')}']", text: "Stacking storage bin"
  end

  test "an empty catalog degrades to a deliberate empty state, not a blank grid" do
    with_reader(StaticReader.new(page: Catalog::ProductReader::Page.new(items: [], next_cursor: nil))) do
      get root_path
    end

    assert_response :success
    assert_select "h3", text: "No sample products yet"
    assert_select "article", count: 0
  end

  test "an unavailable catalog degrades to a deliberate unavailable state, not an error" do
    with_reader(FailingReader.new) { get root_path }

    assert_response :success
    assert_select "h3", text: "Sample catalog unavailable"
    assert_select "article", count: 0
  end

  private
    class StaticReader
      def initialize(page:)
        @page = page
      end

      def list(limit:, cursor: nil)
        @page
      end
    end

    class FailingReader
      def list(limit:, cursor: nil)
        raise Catalog::ProductReader::Error.new(:source_unavailable, retryable: true)
      end
    end

    def with_reader(reader)
      original = ProductsController.method(:build_product_reader)
      ProductsController.define_singleton_method(:build_product_reader) { |**| reader }
      yield
    ensure
      ProductsController.define_singleton_method(:build_product_reader, original)
    end
end
