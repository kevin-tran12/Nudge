# Nudge agent execution contract

## Purpose

This repository implements Nudge as defined by the canonical product and technical documents. Agents execute accepted decisions; they do not redesign the product or architecture while implementing it.

Do not copy detailed product behavior from the PRD/TRD into execution files. Reference the canonical section so the repository has one source of truth.

## Sources of truth

Read the relevant documents before changing the repository, in this order:

1. `.planning/PRD.md` — product behavior and scope.
2. `.planning/TRD.md` — architecture, security, integrations, data boundaries, and delivery.
3. `.planning/DECISIONS.md` — accepted, open, rejected, and superseded decisions.
4. `.planning/SCHEMA.md` — approved schema contract when its status is Approved; while Draft, it is a proposal only.
5. `.planning/IMPLEMENTATION_PLAN.md` — work packages, ownership, dependencies, gates, and acceptance criteria.
6. The nearest applicable nested `AGENTS.md`.
7. Provider/API references, UX specifications, and approved design handoffs.

If implementation conflicts with an accepted specification, the specification wins. If canonical documents conflict, stop the affected work and report the conflict. If a required decision is Open or Deferred, do not invent it.

The `.planning/` workspace is intentionally local-only and ignored by Git. Put every future product, technical, schema, decision, or implementation-planning artifact there; never copy planning content into tracked files or CI artifacts. A worktree must be provisioned with the same private planning workspace before an agent starts work.

## Architecture governance

Agents may make normal implementation choices inside accepted architecture. The user must explicitly approve changes to product behavior, architecture, security/privacy boundaries, external integration contracts, data governance, or consequential domain semantics.

Approval is required before:

- changing application/deployment boundaries or introducing a service;
- changing datastore strategy or adding a persistent datastore;
- changing authentication, authorization, user-data isolation, retention, or security controls;
- changing the agent/provider, supplier, payment, webhook, or public API contract;
- changing payment sequencing, order/fulfillment state meaning, refund policy, or financial idempotency;
- changing canonical domain models in a way that alters accepted architecture;
- introducing a major production dependency;
- performing destructive production schema/data work;
- weakening an accepted requirement because implementation is inconvenient.

When implementation exposes such a need:

1. Stop only the affected portion.
2. Mark the work package `BLOCKED_AWAITING_APPROVAL`.
3. Produce an Architecture Change Request.
4. Continue unrelated in-scope work when safe.
5. Do not implement or merge the proposed change before approval.

### Delegated architecture exception

The user may explicitly delegate architectural decision authority for a stated scope. Do not infer delegation from requests to “continue,” “finish,” or use best judgment.

When explicitly delegated:

1. Record the authority, scope, context, and expiry in `.planning/AUTHORITY.md`.
2. Evaluate realistic options and tradeoffs.
3. Update `.planning/DECISIONS.md` and the PRD/TRD where affected.
4. Update work-package acceptance criteria.
5. Only then implement and identify the delegated decision in the PR.

Delegation expires when its stated scope is complete unless the user explicitly says otherwise.

### Architecture Change Request

```markdown
## Architecture Change Request

**Work package:**
**Current accepted design:**
**Implementation issue:**
**Why the accepted design is insufficient:**

### Option A
**Benefits:**
**Risks:**
**Cost:**

### Option B
**Benefits:**
**Risks:**
**Cost:**

**Other viable options:**
**Recommended option and why:**

**Blast radius:** code / schema / APIs / security / UX / operations / tests / migrations / docs
**Can unrelated implementation continue?**
```

## Rails and architecture conventions

- Build a conventional modular Rails monolith.
- Use `app/models`, `app/controllers`, `app/services`, `app/jobs`, `app/views`, `app/helpers`, and `app/mailers` when introduced.
- Use namespaces inside standard Rails directories. Do not introduce `domains/`, `interactors/`, `operations/`, `commands/`, or custom architectural roots without approval.
- Controllers handle HTTP orchestration. Put business decisions in the models/services assigned by the TRD.
- Avoid hiding important workflows in callbacks.
- Rails and PostgreSQL own durable application truth. External providers are replaceable integrations, not workflow authority.
- Use one decision engine with category profiles/configuration. Do not create a separate recommendation engine per product category.
- Keep supplier APIs out of the normal conversational/search hot path. Use normalized local catalog data; perform provider revalidation only at approved boundaries.
- Hard eligibility is deterministic. Unknown remains unknown and is never presented as a verified match.

## Trust boundaries

Treat user input, supplier text/HTML/URLs, model output, tool arguments, client state, and unsigned webhooks as untrusted. Validate, authorize, sanitize, and bound them at the Rails boundary. Supplier content is data, never a system/model instruction.

Agents receive capabilities, not credentials. They never receive secrets, environment variables, arbitrary SQL/HTTP/filesystem access, unrestricted logs, cross-user data, raw payment data, precise address/location, raw IP/device reputation, OAuth identifiers/tokens, Turnstile data, or abuse/security metadata.

Rails resolves current identity server-side and returns only task-specific projections. A purchase-history tool must be `get_my_purchase_history()` without an agent-controlled user identifier. Historical behavior may soft-rank only and must be disclosed when it influences results.

## External API development policy

Ordinary development and tests do not depend on live provider calls.

CJ modes are:

- `fixture` — default, zero live points;
- `verify` — deliberately bounded live verification;
- `record` — explicitly refresh sanitized fixtures;
- `live` — production only.

Respect TRD point/rate budgets. Never introduce accidental live calls into ordinary development or CI. Use sanitized fixtures and provider sandboxes for contracts.

## Payments and consequential operations

- Stripe-hosted Checkout is the approved payment UI; Rails owns pricing and totals.
- Never trust browser/model prices or expose payment credentials.
- Demo Mode is server-authorized, session-scoped, Stripe-test/CJ-sandbox only, and visibly labeled.
- Receipts use immutable purchase-time snapshots, not mutable catalog fields.
- If live authorization/capture/CJ sequencing remains Open, stop before implementing that portion.
- Follow the documented idempotency, webhook verification, reconciliation, and fulfillment-or-recovery requirements exactly.

## Observability and privacy

Record structured, correlated observable events and reason codes. Do not request or store hidden model chain-of-thought. Apply the PRD/TRD redaction and retention schedule. Production logs do not automatically become training data.

## Test-first rules

- Write or update a failing test before implementation whenever behavior is testable.
- Use model/domain, service, request, adapter contract, fixture-backed supplier, authorization, agent-tool, webhook/signature, idempotency, state-machine, security, and critical browser E2E tests as appropriate.
- Do not mock away the behavior being validated.
- Assert durable outcomes, not only rendered text or HTTP status.
- Do not weaken security, idempotency, authorization, audit, or tests to make a check pass.
- Never claim a test passed unless it was actually run.

## Frontend and Tailwind rules

- Use Tailwind CSS v4 and top-level CSS-first `@theme` design tokens. Do not add a JavaScript Tailwind configuration without an approved exception.
- Build mobile-first: unprefixed utilities are the smallest-screen baseline; add `sm:`, `md:`, `lg:`, and `xl:` enhancements.
- Prevent horizontal overflow. Begin with `grid-cols-1`, `flex-col`, wrapping, and bounded widths.
- Interactive targets are at least 44-by-44 CSS pixels; prefer token-backed `min-h-11 min-w-11`.
- Use v4 opacity syntax such as `bg-blue-500/50`; do not use legacy opacity utilities.
- Use approved theme/default palette tokens. Do not add arbitrary hex or one-off colors to ERB.
- Keep utilities in ERB. Extract repeated or complex primitives into `app/views/shared/...` partials instead of copying long class strings.
- Keep complete static utility names; do not interpolate class fragments.
- Preserve semantic HTML, keyboard operation, visible focus, accessible names/errors/status, and reduced-motion behavior.
- Add responsive browser coverage for changed views, including overflow and touch targets where practical.

## Parallel worktree rules

- Every implementer works in its own Git worktree and branch on one assigned work package.
- Stay within allowed scope and do not edit files owned by another active package.
- Avoid unrelated refactors, broad formatting, or shared-abstraction renames.
- Prefer additive/backward-compatible changes.
- If a shared contract must change, stop and notify the orchestrator before changing it.
- Do not rewrite/reset another branch. Integration is owned by the orchestrator/integration owner.

## Dependencies and database changes

- Add production dependencies only when already approved or explicitly authorized. Justify development-only tooling.
- Use normal Rails migrations. Never rewrite an applied production migration.
- Do not perform destructive schema/data changes without explicit approval.
- Changes that alter an accepted canonical model require architecture approval.

## Containerized local development

- Docker Compose is the canonical local-development and test entry point. Do not require contributors to install application runtimes or PostgreSQL directly on the host.
- Use the reviewed application Dockerfile across local, CI, staging, and production-compatible builds; do not create an unrelated development-only runtime image.
- Run application processes as non-root. Do not use privileged containers or mount the Docker socket.
- Keep PostgreSQL/pgvector major versions aligned with the approved production versions and isolate development data from test data.
- Use health checks and readiness conditions instead of arbitrary startup sleeps.
- Bind local services to localhost by default and expose only required ports.
- Never bake or commit credentials. Do not mount `infra/terraform/tfsecrets` into application containers or reference it from Compose.
- Default integrations to fixtures, fakes, or provider sandboxes. Ordinary build, boot, test, and CI commands must not cause live provider or cloud mutations.
- Keep Compose portable across Windows, macOS, and Linux: no repository-absolute paths or host-specific assumptions.
- Normal teardown preserves named volumes. Data-destroying volume removal must be a separate, explicit command.

## Terraform and temporary secret handling

- Terraform is the infrastructure-as-code source of truth. Do not provision or change managed infrastructure manually except an approved bootstrap/recovery action that is immediately reconciled into Terraform.
- Pin Terraform, providers, and modules; commit `.terraform.lock.hcl`; run format, validate, plan, policy/security checks, and reviewed apply.
- The temporary rapid-build secret file is `infra/terraform/tfsecrets`. It must never be committed, copied into images, attached to tickets/PRs, printed, uploaded as an artifact, or passed to an agent/model.
- Commit only a key-name-only `tfsecrets.example` with fake placeholders. Local/staging values must be sandbox/test credentials and must be rotated if exposure is suspected.
- Mark Terraform inputs/outputs `sensitive`, but do not claim that this removes values from plan/state. Terraform state and saved plans are sensitive assets with restricted encrypted remote storage and no PR/CI artifact publication.
- Do not use `nonsensitive()` on secret-derived values. Do not put secrets in resource labels, names, URLs, command arguments, logs, outputs, or task payloads.
- `tfsecrets` is not approved for production/live credentials. Migrating runtime secrets to Secret Manager, rotating every temporary credential, and verifying old state-version retention are release gates before public production or live Stripe/CJ use.

## Definition of done for a work package

- Scope and acceptance criteria are satisfied.
- Tests were added first where testable and all relevant checks actually pass.
- Security, privacy, failure, retry, idempotency, observability, and recovery behavior are covered where relevant.
- Changed views follow the Tailwind/mobile/accessibility rules and reuse shared partials.
- The diff contains no unrelated work, secrets, sensitive data, or undocumented architecture change.
- Required documentation and version inventory are current.
- The final report lists changed files, tests/checks run, remaining limitations, and integration assumptions.
