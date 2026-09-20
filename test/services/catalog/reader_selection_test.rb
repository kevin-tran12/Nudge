require "test_helper"

class CatalogReaderSelectionTest < ActiveSupport::TestCase
  def environment(name)
    ActiveSupport::EnvironmentInquirer.new(name)
  end

  test "serves imported supplier data in the deployments that have it" do
    %w[staging production].each do |name|
      reader = Catalog::ReaderSelection.call(environment: environment(name), env: {})
      assert_instance_of Catalog::DatabaseProductReader, reader, "#{name} must read real data"
    end
  end

  test "serves fixtures in local deployments" do
    %w[development test].each do |name|
      reader = Catalog::ReaderSelection.call(environment: environment(name), env: {})
      assert_instance_of Catalog::FixtureProductReader, reader
    end
  end

  test "an explicit override selects the reader in any deployment" do
    reader = Catalog::ReaderSelection.call(environment: environment("development"),
      env: { "CATALOG_READER" => "database" })
    assert_instance_of Catalog::DatabaseProductReader, reader

    reader = Catalog::ReaderSelection.call(environment: environment("production"),
      env: { "CATALOG_READER" => "fixture" })
    assert_instance_of Catalog::FixtureProductReader, reader
  end

  # A typo must not quietly serve fixtures where real data was required, so an
  # unrecognized override fails closed rather than falling back to a default.
  test "an unrecognized override fails closed instead of falling back" do
    [ "", "Database", "postgres", "fixtures" ].each do |value|
      error = assert_raises(Catalog::ProductReader::Error) do
        Catalog::ReaderSelection.call(environment: environment("production"),
          env: { "CATALOG_READER" => value })
      end
      assert_equal :source_unavailable, error.code
    end
  end

  test "an unmapped deployment fails closed" do
    error = assert_raises(Catalog::ProductReader::Error) do
      Catalog::ReaderSelection.call(environment: environment("qa"), env: {})
    end
    assert_equal :source_unavailable, error.code
  end

  # The defect this seam exists to prevent: the catalog serving real products
  # while the cart resolves variants against fixtures.
  test "the cart resolver and the catalog page agree on the reader" do
    with_env("CATALOG_READER", "database") do
      assert_instance_of Catalog::DatabaseProductReader, ProductsController.build_product_reader
      assert_instance_of Catalog::DatabaseProductReader,
        Cart::CatalogVariantResolver.new.instance_variable_get(:@product_reader)
    end
  end

  private
    def with_env(key, value)
      previous = ENV[key]
      ENV[key] = value
      yield
    ensure
      ENV[key] = previous
    end
end
