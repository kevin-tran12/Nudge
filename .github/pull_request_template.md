## Work package

WP-

## Summary

What user/business outcome was implemented?

## Specification references

- PRD:
- TRD:
- Canonical decisions:
- Implementation plan:
- Applicable `AGENTS.md` files:

## Acceptance criteria

- [ ]

## Tests and checks actually run

- [ ] Unit/domain/service
- [ ] Request/integration/contract
- [ ] Authorization/security
- [ ] Browser/system/E2E
- [ ] Lint/static/dependency/secret/container scans
- [ ] Migration/rollback or infrastructure validation
- [ ] Other:

Commands and results:

## Durable outcome and failure behavior

What durable state proves success? How do timeout, retry, duplicate, partial, and provider failures behave?

## Security and privacy impact

Does this change affect any of the following?

- [ ] authentication or authorization
- [ ] customer/user data or agent projections
- [ ] secrets/IAM
- [ ] payments/orders/refunds/receipts
- [ ] agents/tools/provider sessions
- [ ] supplier integrations or server-side fetching
- [ ] webhooks
- [ ] admin/Demo Mode
- [ ] rate limits/abuse controls
- [ ] logging/retention/training data
- [ ] browser CSP/CSRF/CORS/origins
- [ ] Terraform state/plan or `tfsecrets` handling

If selected, describe controls and reviewer evidence:

## Architecture

- [ ] No architectural change
- [ ] Implements an accepted architectural decision
- [ ] Decision made under explicit delegated authority

Decision/authority reference:

If this PR requires an unapproved architecture/product/security change, stop and mark the package `BLOCKED_AWAITING_APPROVAL`.

## External API behavior

Any live calls introduced? Which fixture/sandbox/verify mode covers them? How are rate/point/cost budgets enforced?

## Database changes

Migrations and compatibility:

Backfill/destructive behavior:

Rollback/restore implications:

## Infrastructure and secrets

Terraform plan reference and reviewed changes:

Does any value enter Terraform state or a saved plan? How is access/retention controlled?

Confirm no real `tfsecrets`, `.tfvars`, plan, or state file is included in the PR/artifacts/logs:

## Frontend impact

Mobile states/breakpoints, shared partials/tokens, keyboard/focus behavior, overflow/touch-target checks:

## Reviewer checklist

- [ ] Matches work-package acceptance criteria and PRD/TRD
- [ ] No undocumented architecture change
- [ ] Tests assert durable outcomes and important failures
- [ ] Security/data boundaries preserved
- [ ] No secrets or unnecessary sensitive data introduced
- [ ] Observability and recovery included where required
- [ ] Documentation/version inventory updated
- [ ] General review `APPROVED`
- [ ] Security review `APPROVED` when required

## Known limitations and follow-up

