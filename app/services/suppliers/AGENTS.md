# Supplier integration instructions

These instructions supplement the repository root `AGENTS.md`.

- CJ is supplier implementation one; it does not define canonical application schema.
- Keep CJ authentication, endpoints, field names, pagination, points, signatures, and errors behind the supplier adapter.
- Default development/CI to fixture mode. Live calls require an explicitly invoked `verify`, `record`, or production `live` mode and must respect TRD budgets.
- Preserve sanitized raw observations where the schema/TRD requires provenance, debugging, fixture regression, or renormalization. Never store/commit credentials.
- Treat supplier HTML, text, payloads, media URLs, and identifiers as untrusted. Sanitize HTML and apply SSRF controls before any server-side fetch.
- Preserve native values, canonical normalized values, provenance, and freshness. Never invent missing attributes.
- Normal shopping/search uses local normalized catalog data. Only approved transaction-critical boundaries call CJ synchronously/asynchronously for revalidation.
- Changes to supplier contracts, canonical identity, ingestion architecture, routing, inventory scope, or freshness semantics require architecture approval.
