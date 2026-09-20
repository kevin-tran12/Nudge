# CJ fixture contract v1

These are synthetic, sanitized fixtures authored on 2026-09-20 from the documented API shapes. They are not captured supplier observations, current stock, checkout prices, or proof of destination eligibility. Product/variant/SKU values, timestamps, images, carrier names, and quantities are fake. No fixture URL is fetched.

Sources reviewed:

- [CJ product and inventory documentation](https://developers.cjdropshipping.com/en/api/api2/api/product.html): `product/query` and `product/stock/queryByVid`.
- [CJ logistics documentation](https://developers.cjdropshipping.com/en/api/api2/api/logistic.html): `logistic/freightCalculate`, an estimate rather than route validation.
- [CJ error codes](https://developers.cjdropshipping.com/en/api/api2/standard/ps-code.html): classify by numeric code, never by provider message text.

`Integrations::Cj::Adapter` exposes `product(product_id:)`, `inventory(variant_id:)`, and `freight(origin_country:, destination_country:, items:)`. Each returns immutable normalized data, the exact normalized request context, and version/hash/time provenance. Missing quantities, prices, measurements, fees, and expiry remain unknown. Product, variant, SKU, warehouse area, and subwarehouse references remain distinct. Freight eligibility is always unknown in this slice.

The default mode is `fixture`; it does not read environment variables or credentials. Passing `verify`, `record`, `live`, or an unknown mode fails closed. The optional fixture scenario is limited to `success`, `malformed`, `throttled`, and `expired_auth`. Only requests matching a fixture entry's request are supported; a mismatch never falls through to HTTP.

Each `v1/{product,inventory,freight}.json` file is `fixture_version: 2`: a shared `observed_at` plus an `entries` array of `{request, response}` pairs, looked up by exact request match (v1 held exactly one pair per file; a stale or absent `fixture_version` still fails closed). `product.json` now describes an 8-item sample catalog spanning kitchen, storage, desk/office, travel, pet, and lighting categories, with varied prices, 1-3 variants each, and deliberate imperfection: an unknown price, an out-of-stock variant, a product with no image, and one product description containing an inert instruction-injection string used only to prove supplier text is never treated as an instruction. `00001234` (the original storage bin) and its sole `inventory.json` entry are unchanged byte-for-byte. This `entries` restructuring is unrelated to `Integrations::Cj::RecordArtifactValidator`'s own `fixture_version: 1` single-envelope artifact format described below, which still validates one captured `{fixture_version, observed_at, request, response}` envelope at a time.

Errors expose a fixed reason code and `retry_strategy`: `never`, `backoff`, or `pause`. The adapter does not sleep, retry, rotate credentials, or dispatch network requests. Authentication and exhausted quota require a pause; only classified throttling/transient failures permit a future bounded retry policy. No provider message or raw payload is logged or attached to exceptions.

Bounds are deliberately conservative: IDs 200 bytes; response bodies 256 KiB/12 JSON nesting levels; product variants 200; images 50; warehouses/subwarehouses/freight options 100; freight request items 1–100 with unique variant IDs and quantities 1–10,000. Money is exact USD minor units. Decimal magnitude and exponent are bounded before serialization. Text is bounded and never marked HTML-safe; descriptions/labels have markup and active content removed, while SKU references retain their native text and must be escaped when rendered.

Media references allow only HTTPS/443 on exact documented hosts, with no credentials, query, fragment, encoded path, or parent traversal. This is validation of references, not a fetcher: future media fetching still needs DNS/IP and redirect controls. Future network modes require current sanitized contract capture, authentication, the point/rate governor, and separate transport tests before enablement. No fixture result can authorize live fulfillment.

Run the database-independent adapter behavior inside the standard Rails contract lane:

```bash
docker compose run --rm -e RAILS_ENV=test app bin/rails test test/contracts/cj_adapter_contract_test.rb
```

The Rails test harness itself requires the isolated test database to be prepared as described in the repository README. The adapter makes no database queries. These tests are also discovered by `bin/test-integration` and `bin/test-all`.

## Offline record-artifact validation

`Integrations::Cj::RecordArtifactValidator` is the offline gate for a future,
owner-authorized `record` runner. It accepts an explicit approved operation, the
operation's already-normalized request, raw response bytes, and an explicit UTC
observation timestamp. It does not select a mode, obtain credentials, spend
points, make network or database calls, retry, sleep, read a clock, choose a
path, or write a file.

The validator accepts only the documented v1 product, inventory, and freight
shapes represented here. It rejects duplicate JSON keys, unexpected fields,
credential/customer/signature fields, active markup, malformed values, unsafe
media references, and response/request identity mismatches. Unknown provider
fields require review before the v1 allowlists change; they are never silently
recorded. Provider diagnostic `message` text is omitted from generated
artifacts.

A successful call returns immutable canonical JSON bytes, their SHA-256 digest,
and the normalized result with record-artifact provenance. The canonical JSON
has the same `fixture_version`, `observed_at`, `request`, and `response` envelope
used by these fixtures and can be replayed through the existing normalizer.
Identical inputs produce identical bytes and hashes. The caller remains
responsible for any later reviewed filesystem write and deduplication.
Decimal JSON numbers are parsed without passing through binary floating point
and are emitted as JSON numbers, preserving accepted measurement precision on
replay. Every numeric value is bounded before provider diagnostics are removed.
Implicit string/log rendering exposes metadata only, and YAML/Psych and Marshal
serialization of the result are refused; callers must deliberately access
`artifact_bytes` or `normalized`.

This gate does not enable `verify`, `record`, or `live` transport. Before a
transport is connected, current official evidence must establish the exact API
origin, method/path, authentication headers and token response, HTTP error and
retry semantics, redirects, per-operation point costs, and idempotency support.
