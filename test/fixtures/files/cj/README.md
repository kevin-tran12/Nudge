# CJ fixture contract v1

These are synthetic, sanitized fixtures authored on 2026-09-20 from the documented API shapes. They are not captured supplier observations, current stock, checkout prices, or proof of destination eligibility. Product/variant/SKU values, timestamps, images, carrier names, and quantities are fake. No fixture URL is fetched.

Sources reviewed:

- [CJ product and inventory documentation](https://developers.cjdropshipping.com/en/api/api2/api/product.html): `product/query` and `product/stock/queryByVid`.
- [CJ logistics documentation](https://developers.cjdropshipping.com/en/api/api2/api/logistic.html): `logistic/freightCalculate`, an estimate rather than route validation.
- [CJ error codes](https://developers.cjdropshipping.com/en/api/api2/standard/ps-code.html): classify by numeric code, never by provider message text.

`Integrations::Cj::Adapter` exposes `product(product_id:)`, `inventory(variant_id:)`, and `freight(origin_country:, destination_country:, items:)`. Each returns immutable normalized data, the exact normalized request context, and version/hash/time provenance. Missing quantities, prices, measurements, fees, and expiry remain unknown. Product, variant, SKU, warehouse area, and subwarehouse references remain distinct. Freight eligibility is always unknown in this slice.

The default mode is `fixture`; it does not read environment variables or credentials. Passing `verify`, `record`, `live`, or an unknown mode fails closed. The optional fixture scenario is limited to `success`, `malformed`, `throttled`, and `expired_auth`. Only requests matching the versioned fixture's request are supported; a mismatch never falls through to HTTP.

Errors expose a fixed reason code and `retry_strategy`: `never`, `backoff`, or `pause`. The adapter does not sleep, retry, rotate credentials, or dispatch network requests. Authentication and exhausted quota require a pause; only classified throttling/transient failures permit a future bounded retry policy. No provider message or raw payload is logged or attached to exceptions.

Bounds are deliberately conservative: IDs 200 bytes; response bodies 256 KiB/12 JSON nesting levels; product variants 200; images 50; warehouses/subwarehouses/freight options 100; freight request items 1–100 with unique variant IDs and quantities 1–10,000. Money is exact USD minor units. Decimal magnitude and exponent are bounded before serialization. Text is bounded and never marked HTML-safe; descriptions/labels have markup and active content removed, while SKU references retain their native text and must be escaped when rendered.

Media references allow only HTTPS/443 on exact documented hosts, with no credentials, query, fragment, encoded path, or parent traversal. This is validation of references, not a fetcher: future media fetching still needs DNS/IP and redirect controls. Future network modes require current sanitized contract capture, authentication, the point/rate governor, and separate transport tests before enablement. No fixture result can authorize live fulfillment.

Run the database-independent adapter behavior inside the standard Rails contract lane:

```bash
docker compose run --rm -e RAILS_ENV=test app bin/rails test test/contracts/cj_adapter_contract_test.rb
```

The Rails test harness itself requires the isolated test database to be prepared as described in the repository README. The adapter makes no database queries. These tests are also discovered by `bin/test-integration` and `bin/test-all`.
