# Nudge agentic engineering workflow

## Goal

Run test-first implementation with parallel agents while preserving one accepted product, architecture, security model, and integration contract.

```text
PRD/TRD          what and how
Decision log     accepted governance state
AGENTS.md        implementer constraints
Implementation  bounded work packages and dependencies
Workflow         assignment, review, and merge process
CI               objective quality gate
User             product/architecture authority
```

## Roles

### User / product-architecture authority

Owns the PRD, product behavior, architecture, security/data boundaries, and approval of architectural changes. Authority remains with the user unless explicitly delegated for a defined scope.

### Orchestrator / integration owner

- reads the canonical documents and implementation plan;
- identifies READY work packages and dependency order;
- allocates non-overlapping file ownership/worktrees;
- supplies implementers with scope, references, acceptance criteria, and required tests;
- assigns independent general/security review;
- routes findings back to implementers;
- monitors CI and merge gates;
- merges approved work when authorized;
- escalates architecture/product/security questions.

The orchestrator avoids substantial feature implementation. It may make trivial integration/conflict edits that do not change behavior or contracts.

### Implementer

Owns one bounded work package, follows all applicable `AGENTS.md` files, writes tests first, implements only assigned scope, performs self-review, runs checks, opens/updates the PR, and responds to findings. Implementers do not make unapproved architecture decisions.

### Independent reviewer

Reviews against acceptance criteria, canonical documents, applicable instructions, regression risk, and test evidence. The reviewer does not rewrite the feature during review.

Statuses:

- `APPROVED`
- `CHANGES_REQUESTED`
- `BLOCKED_ARCHITECTURE_DECISION`

### Security reviewer

Required for authentication/authorization, user-data access, agent tools/provider sessions, Turnstile, Stripe, orders/refunds, Demo Mode, webhooks, abuse/rate limits, logging/retention, guest receipt access, admin features, secrets, and supplier HTTP/SSRF surfaces.

## Work-package lifecycle

```text
PLANNED
  ↓
READY
  ↓
ASSIGNED
  ↓
IMPLEMENTING
  ↓
SELF_REVIEW
  ↓
PR_OPEN
  ↓
CODE_REVIEW
  ↓
SECURITY_REVIEW (when required)
  ↓
CI_VALIDATION
  ↓
READY_TO_MERGE
  ↓
MERGED
```

`CHANGES_REQUESTED` returns to `IMPLEMENTING`. `BLOCKED_AWAITING_APPROVAL` pauses only the affected scope.

## Required work-package contract

Every assignment includes:

- ID, title, purpose, and status;
- dependencies and expected contracts consumed/produced;
- allowed files/systems and explicit out-of-scope areas;
- PRD, TRD, decision, and `AGENTS.md` references;
- measurable acceptance criteria;
- tests/checks to write and run;
- security-review requirement;
- accepted architecture decisions;
- Open/Deferred decisions that must not be implemented.

UI packages additionally identify mobile states, responsive breakpoints, tokens/partials, keyboard/focus behavior, and viewport checks.

## Assignment and parallelism

Before assigning work, the orchestrator confirms:

1. dependencies are merged or a stable contract branch exists;
2. no Open decision blocks the package;
3. owned files do not materially overlap active packages;
4. relevant specifications and nested instructions are included;
5. acceptance criteria and review requirements are explicit.

Parallelize independent adapters, isolated UI components, fixtures/tests, documentation, and non-overlapping services. Merge contract-defining work before parallel consumers. Do not assign two agents to redefine the same model, migration, API, schema, or shared abstraction.

## Architecture-change workflow

If implementation requires a product, architecture, security, integration, or data-governance change:

1. stop affected work;
2. prepare the Architecture Change Request from root `AGENTS.md`;
3. mark the package `BLOCKED_AWAITING_APPROVAL`;
4. continue unrelated safe scope;
5. obtain explicit user approval or rejection;
6. update the canonical decision log and PRD/TRD;
7. update acceptance criteria;
8. resume only after documentation is authoritative.

Explicit delegated architecture mode follows root `AGENTS.md`. The authority record and resulting decisions must exist before merge.

## Review loop

The reviewer returns:

- blocking findings;
- non-blocking findings;
- architecture concerns;
- test gaps;
- one explicit review status.

The orchestrator sends blocking findings to the original implementer when practical. Re-review continues until approved or blocked. “Looks good” does not override objective gates.

## High-risk review matrix

| Subsystem | General review | Security review |
|---|---:|---:|
| Basic presentation/UI | Required | Usually not required |
| Catalog normalization/parsing | Required | Required for untrusted fetching/parsing |
| Search/retrieval | Required | Required if user-data boundaries change |
| Agent tools/ElevenLabs session | Required | Required |
| User-data access | Required | Required |
| Turnstile/Google OIDC | Required | Required |
| Stripe/checkout/orders/refunds | Required | Required |
| Demo Mode | Required | Required |
| Webhooks | Required | Required |
| Admin functionality | Required | Required |
| Supplier HTTP/SSRF | Required | Required |
| Infrastructure/IAM/deployment | Required | Required |

## Merge gates

A PR may merge only when:

- work-package criteria are satisfied;
- relevant scoped and full/subsystem tests pass;
- lint, static analysis, security, dependency, secret, and migration checks pass as applicable;
- browser/E2E evidence exists for affected critical journeys;
- general review is `APPROVED`;
- security review is `APPROVED` when required;
- CI is green;
- no blocking findings or undocumented architectural changes remain;
- no secrets/sensitive data were introduced;
- documentation, migrations, lockfiles, and version inventory are consistent.

The orchestrator may merge normal implementation after all gates pass. Human approval remains required for unresolved architecture/security changes, major unapproved production dependencies, destructive production operations, and decisions reserved in the PRD/TRD.

## CI failure workflow

1. Classify the failure as implementation, test, environment/flaky, security, migration, or provider-contract related.
2. Return it to the owning implementer.
3. Fix the cause without weakening valid assertions or controls.
4. Rerun the narrow reproduction, then required broader checks and CI.
5. Repeat until green or explicitly blocked.

## Merge conflicts

The orchestrator resolves trivial, non-semantic conflicts. Conflicts affecting behavior, architecture, public/internal contracts, schema meaning, migrations, or security return to the owning implementer/reviewer or user authority.

## Post-merge

- mark the work package MERGED;
- record the PR/commit and verified checks;
- unblock dependent packages;
- confirm canonical docs remain consistent;
- record follow-up debt explicitly rather than leaving hidden TODO assumptions.

No silent architectural debt.
