require "test_helper"

# CAT-SYNC-01 (Prodigi phase). The DTOs ArtifactImporter actually consumes
# (Result/Provenance/Money/Measurement/Product/Variant) were CJ-namespaced
# even though nothing about their shape is CJ-specific. This phase lifts them
# into Integrations::Contracts and makes Integrations::Cj::Contracts alias
# them rather than fork them, so a second supplier can hand the importer the
# same shape without reaching into the CJ namespace. CJ-only types
# (Inventory, Subwarehouse, Freight, ProductSummary, ProductListPage) stay
# CJ-only and untouched.
class IntegrationsContractsTest < ActiveSupport::TestCase
  test "the neutral contracts exist with the expected fields" do
    assert_equal %i[value provenance request].sort,
      Integrations::Contracts::Result.members.sort
    assert_equal %i[provider source endpoint_key adapter_version payload_version payload_sha256
      observed_at request_id].sort, Integrations::Contracts::Provenance.members.sort
    assert_equal %i[amount_minor currency].sort, Integrations::Contracts::Money.members.sort
    assert_equal %i[value unit].sort, Integrations::Contracts::Measurement.members.sort
    # attributes: a small allowlisted hash for supplier-native structured
    # values that don't fit a typed field (seller identity, popularity,
    # material, ships-to countries) -- not free text.
    assert_equal %i[external_id sku title description image_urls variants attributes].sort,
      Integrations::Contracts::Product.members.sort
    # options sits alongside the pre-existing option_label field (added by
    # PR #39); it is not a replacement for it.
    assert_equal %i[external_id product_id sku title option_label options price weight length
      width height].sort, Integrations::Contracts::Variant.members.sort
  end

  test "CJ's own contracts alias the shared DTOs instead of forking them" do
    assert_same Integrations::Contracts::Result, Integrations::Cj::Contracts::Result
    assert_same Integrations::Contracts::Provenance, Integrations::Cj::Contracts::Provenance
    assert_same Integrations::Contracts::Money, Integrations::Cj::Contracts::Money
    assert_same Integrations::Contracts::Measurement, Integrations::Cj::Contracts::Measurement
    assert_same Integrations::Contracts::Product, Integrations::Cj::Contracts::Product
    assert_same Integrations::Contracts::Variant, Integrations::Cj::Contracts::Variant
  end

  test "CJ-only shapes remain defined only in the CJ namespace" do
    refute Integrations::Contracts.const_defined?(:Inventory)
    refute Integrations::Contracts.const_defined?(:Subwarehouse)
    refute Integrations::Contracts.const_defined?(:Freight)
    refute Integrations::Contracts.const_defined?(:ProductSummary)
    refute Integrations::Contracts.const_defined?(:ProductListPage)

    assert Integrations::Cj::Contracts.const_defined?(:Inventory)
    assert Integrations::Cj::Contracts.const_defined?(:Subwarehouse)
    assert Integrations::Cj::Contracts.const_defined?(:Freight)
    assert Integrations::Cj::Contracts.const_defined?(:ProductSummary)
    assert Integrations::Cj::Contracts.const_defined?(:ProductListPage)
  end

  # Integrations::Cj::Normalizer builds Contracts::Product / Contracts::Variant
  # without ever passing attributes: or options: (verified in
  # app/services/integrations/cj/normalizer.rb). For that pre-existing,
  # unmodified caller to keep working unchanged, both new fields must default
  # to an empty hash rather than require the caller to supply them.
  test "the new attributes and options fields default to an empty hash" do
    product = Integrations::Contracts::Product.new(external_id: "1", sku: nil, title: "t",
      description: nil, image_urls: nil, variants: [])
    assert_equal({}, product.attributes)

    variant = Integrations::Contracts::Variant.new(external_id: "1", product_id: "1", sku: nil,
      title: nil, option_label: nil, price: nil, weight: nil, length: nil, width: nil, height: nil)
    assert_equal({}, variant.options)
  end

  test "deep_freeze recursively freezes a DTO and its nested hash/array values" do
    product = Integrations::Contracts::Product.new(external_id: "1", sku: nil, title: "t",
      description: nil, image_urls: [ "https://example.test/a.jpg" ], variants: [],
      attributes: { "material" => "steel" })

    frozen = Integrations::Contracts.deep_freeze(product)

    assert_same product, frozen
    assert frozen.frozen?
    assert frozen.image_urls.frozen?
    assert frozen.attributes.frozen?
  end
end
