require "test_helper"
require "json"

# CJ-LIVE-IMPORT-01. reject_active_content! used to refuse any HTML element
# carrying any attribute at all. Real CJ product descriptions and list remarks
# are ordinary marketing HTML built from <img src=...>, <br/>, <b> and
# style="max-width:100%", so that blanket rule made every genuine product
# unstorable: product and product_list both failed as :malformed_response
# against live captures while inventory, which carries no HTML, passed.
#
# The rule now rejects only what can execute or exfiltrate: on* handlers,
# dangerous URL schemes in any attribute value, and the
# srcdoc/formaction/xlink:href navigation vectors. Active *elements* are
# rejected exactly as before.
#
# Entirely offline: every byte here is a literal in this file or in
# TestSupport::CjLiveResponseShapes.
class CjRecordArtifactActiveContentTest < ActiveSupport::TestCase
  include TestSupport::CjLiveResponseShapes

  OBSERVED_AT = "2026-09-20T00:00:00Z".freeze
  Validator = Integrations::Cj::RecordArtifactValidator

  # --- the rule itself -----------------------------------------------------

  test "a presentational img inside a description validates" do
    fragment = %(<img src="https://oss-cf.cjdropshipping.com/x.jpg" style="max-width:100%">)

    result = validate_product(description: fragment)

    assert_equal :product, result.operation
  end

  test "every benign presentational attribute real supplier HTML uses is permitted" do
    %w[src alt width height style class title].each do |attribute|
      result = validate_product(description: %(<img src="#{LIVE_IMAGE}" #{attribute}="10"/>))

      assert_equal :product, result.operation, "#{attribute} should be permitted"
    end
  end

  test "an href to an ordinary http or https URL is permitted" do
    [ "https://cjdropshipping.com/p/1", "http://cjdropshipping.com/p/1", "/p/1", "#anchor" ].each do |href|
      result = validate_product(description: %(<a href="#{href}">Listing</a>))

      assert_equal :product, result.operation, "#{href} should be permitted"
    end
  end

  test "active elements are still rejected" do
    %w[script style template iframe object].each do |element|
      assert_malformed("<#{element}> should be rejected") do
        validate_product(description: "<p>Safe</p><#{element}>SYNTHETIC-SECRET</#{element}>")
      end
    end
  end

  test "any event handler attribute is rejected" do
    %w[onclick onerror onload onmouseover ONCLICK OnError onfocusin].each do |attribute|
      assert_malformed("#{attribute} should be rejected") do
        validate_product(description: %(<img src="#{LIVE_IMAGE}" #{attribute}="SYNTHETIC-SECRET"/>))
      end
    end
  end

  test "a dangerous URL scheme in any attribute value is rejected" do
    [ "javascript:alert(1)",
      "JaVaScRiPt:alert(1)",
      "java\tscript:alert(1)",
      "java\nscript:alert(1)",
      "java\rscript:alert(1)",
      "  javascript:alert(1)",
      "vbscript:msgbox(1)",
      "VBScript:msgbox(1)",
      "data:text/html;base64,U1lOVEhFVElD" ].each do |value|
      assert_malformed("href=#{value.inspect} should be rejected") do
        validate_product(description: %(<a href="#{value}">x</a>))
      end

      assert_malformed("src=#{value.inspect} should be rejected") do
        validate_product(description: %(<img src="#{value}"/>))
      end
    end
  end

  test "an html entity encoded dangerous scheme is rejected" do
    [ "&#106;avascript:alert(1)", "java&#9;script:alert(1)", "&#74;avaScript:alert(1)" ].each do |value|
      assert_malformed("href=#{value.inspect} should be rejected") do
        validate_product(description: %(<a href="#{value}">x</a>))
      end
    end
  end

  test "the srcdoc formaction and xlink href navigation vectors are rejected" do
    [ %(<div srcdoc="anything"></div>),
      %(<button formaction="https://example.com/steal">x</button>),
      %(<a xlink:href="https://example.com/steal">x</a>),
      %(<svg><a xlink:href="https://example.com/steal">x</a></svg>) ].each do |fragment|
      assert_malformed("#{fragment} should be rejected") do
        validate_product(description: fragment)
      end
    end
  end

  test "a dangerous attribute is rejected wherever it hides not only in the description" do
    assert_malformed do
      validate_product(product_pro: %(<b title="javascript:alert(1)">x</b>))
    end

    body = live_list_body
    body["data"]["list"].first["remark"] = %(<img src="#{LIVE_IMAGE}" onerror="alert(1)"/>)
    assert_malformed do
      validator.call(operation: :product_list, request: live_list_request, raw_body: JSON.generate(body),
        observed_at: OBSERVED_AT)
    end
  end

  test "a colon that is not a scheme does not look dangerous" do
    [ "Ratio data : 3", "Note: javascript is not used here", "Style data" ].each do |text|
      result = validate_product(description: %(<b title="#{text}">x</b>))

      assert_equal :product, result.operation, "#{text.inspect} should be permitted"
    end
  end

  # --- the three real response shapes --------------------------------------

  test "a realistic live product response with attribute bearing HTML validates" do
    result = validator.call(operation: :product, request: { "product_id" => LIVE_PRODUCT_ID },
      raw_body: JSON.generate(live_product_body), observed_at: OBSERVED_AT)

    assert_equal LIVE_PRODUCT_ID, result.normalized.value.external_id
    assert_equal [ LIVE_VARIANT_ID, LIVE_SECOND_VARIANT_ID ],
      result.normalized.value.variants.map(&:external_id)
    assert_includes result.artifact_bytes, "oss-cf.cjdropshipping.com"
    assert_includes result.artifact_bytes, "max-width:100%"
  end

  test "a realistic live product list response with HTML remarks and a price range validates" do
    body = live_list_body
    assert_equal "3.49 -- 4.78", body.dig("data", "list").first.fetch("sellPrice")
    assert_includes body.dig("data", "list").first.fetch("remark"), "<img"

    result = validator.call(operation: :product_list, request: live_list_request,
      raw_body: JSON.generate(body), observed_at: OBSERVED_AT)

    assert_equal [ LIVE_LIST_PRODUCT_ID ], result.normalized.value.products.map(&:external_id)
  end

  test "a realistic live inventory response validates" do
    result = validator.call(operation: :inventory, request: { "variant_id" => LIVE_VARIANT_ID },
      raw_body: JSON.generate(live_inventory_body), observed_at: OBSERVED_AT)

    assert_equal [ LIVE_VARIANT_ID ], result.normalized.value.map(&:variant_id)
  end

  test "the live envelope keys and the millisecond createTime are accepted" do
    body = live_product_body
    assert_equal 1_789_557_007_000, body.dig("data", "variants").first.fetch("createTime")
    assert_equal %w[code data message pointsInfo requestId result success], body.keys.sort

    assert_equal :product, validator.call(operation: :product, request: { "product_id" => LIVE_PRODUCT_ID },
      raw_body: JSON.generate(body), observed_at: OBSERVED_AT).operation
  end

  test "the relaxed attribute rule opens no socket" do
    results = refute_socket_opened do
      [ validator.call(operation: :product, request: { "product_id" => LIVE_PRODUCT_ID },
          raw_body: JSON.generate(live_product_body), observed_at: OBSERVED_AT),
        validator.call(operation: :product_list, request: live_list_request,
          raw_body: JSON.generate(live_list_body), observed_at: OBSERVED_AT),
        validator.call(operation: :inventory, request: { "variant_id" => LIVE_VARIANT_ID },
          raw_body: JSON.generate(live_inventory_body), observed_at: OBSERVED_AT) ]
    end

    assert_equal %i[product product_list inventory], results.map(&:operation)
  end

  private
    def validator
      @validator ||= Validator.new
    end

    def assert_malformed(message = nil, &block)
      args = [ Integrations::Cj::Error, message ].compact
      error = assert_raises(*args, &block)
      assert_equal :malformed_response, error.code, message
      refute_includes error.full_message, "SYNTHETIC-SECRET"
    end

    def validate_product(description: LIVE_DESCRIPTION, product_pro: "Durable")
      body = live_product_body
      body["data"]["description"] = description
      body["data"]["productPro"] = product_pro
      validator.call(operation: :product, request: { "product_id" => LIVE_PRODUCT_ID },
        raw_body: JSON.generate(body), observed_at: OBSERVED_AT)
    end
end
