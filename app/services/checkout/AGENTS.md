# Checkout, orders, and payments instructions

These instructions supplement the repository root `AGENTS.md`.

- Use Stripe-hosted Checkout. Rails calculates authoritative totals and never handles raw card credentials.
- Agents may invoke only the approved Rails checkout capability. They never receive Stripe secrets, provider IDs, raw payment data, or billing/address data.
- Perform the TRD-required CJ inventory, supplier-price, freight, destination, and margin validation before checkout and fulfillment submission.
- Demo Mode is admin-authorized, server-controlled, session-scoped, clearly visible, Stripe-test/CJ-sandbox only, and isolated from live credentials/data.
- Verify webhook signatures against raw bodies, persist unique provider events, deduplicate, enqueue, and return quickly. Heavy processing never runs inside webhook requests.
- Idempotency and reconciliation prevent duplicate charges, internal orders, and supplier orders under retries, reconnects, and duplicate/out-of-order events.
- Keep internal order, Stripe payment, and CJ fulfillment state separate. Do not infer one authority's state from another.
- Render historical HTML/PDF receipts from immutable purchase snapshots and one presenter, never current catalog fields.
- If live authorization/capture/CJ-submission sequencing is Open, stop before implementing that portion.
- Payment sequencing, state semantics, refund behavior, financial idempotency, guest receipt authorization, and Demo Mode trust-boundary changes require architecture approval.
