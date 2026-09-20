# Testing and CI

Docker Compose is the reference test environment. Every ordinary test process is locked to `PROVIDER_MODE=fixture` and refuses to run against a database whose name does not end in `test`.

## Test lanes

Prepare the isolated test database before running a lane:

```bash
docker compose up --detach --wait db
docker compose run --rm --no-deps -e RAILS_ENV=test app bin/rails db:prepare
```

Run quick unit, model, service, request, helper, mailer, and job tests:

```bash
docker compose run --rm --no-deps -e RAILS_ENV=test app bin/test-fast
```

Run integration and provider-contract tests:

```bash
docker compose run --rm --no-deps -e RAILS_ENV=test app bin/test-integration
```

Run the complete suite and enforce the initial coverage floor:

```bash
docker compose run --rm --no-deps -e RAILS_ENV=test app bin/test-all
```

The initial gate is 80% line coverage and 60% branch coverage across tracked application and library Ruby files. The three unchanged Rails abstract base classes are excluded because they contain configuration comments and inheritance declarations without application behavior. Remove an exclusion when behavior is added to one of those files. This baseline is enforceable with the foundation code and should rise as domain behavior is added. Partial lanes produce informational coverage without applying the aggregate threshold.

Tests can call `unique_test_value(prefix)` for a process-safe namespace. Database-backed tests continue to use Rails transactional isolation and should create only the records needed for the assertion.

CI uses one Rails test worker for repeatable coverage and failure output. A developer may set `RAILS_TEST_WORKERS` to exercise process isolation locally; this does not replace the single-worker coverage gate.

## Browser E2E status

`bin/test-browser` is the reserved browser entry point. It currently exits with an error because no production-like browser environment or `test/system` journey is registered. Do not add it as a green CI check or claim browser coverage until a pinned browser/driver image and real journeys exist. Staging browser E2E remains a later release gate.

## CI evidence and failure behavior

GitHub Actions runs the fast lane, integration/contract lane, and full coverage gate before uploading coverage HTML and plain test logs for 14 days. The shell uses `pipefail`, so logging cannot hide a failing test. Quality and production-security jobs independently gate lint, Ruby dependency audit, Brakeman, repository secret/misconfiguration scanning, production build and eager load, and operating-system container vulnerabilities. No JavaScript import map is installed yet; add an executable JavaScript dependency audit when client-side packages are introduced.

To verify failure propagation locally, temporarily select a nonexistent test or add a deliberate failing assertion on a disposable branch; the lane must return nonzero and the workflow must retain the corresponding log. Never commit an intentional failure or bypass a failing command with `continue-on-error`, `|| true`, or a zero-exit wrapper.

## FND-01 integration gate

FND-01 owns `test/runtime/production_image_contract.rb` and the pruned production bundle. After rebasing this branch onto merged FND-01, add the following step immediately after `Build production image` in the `production-security` job:

```yaml
- name: Verify production image contract
  run: docker run --rm -e RAILS_ENV=production -e SECRET_KEY_BASE_DUMMY=1 "$CI_IMAGE" ruby test/runtime/production_image_contract.rb
```

The contract must fail if the runtime contains development/test gems, runs as root, has an incomplete production bundle, or cannot eager-load Rails. Do not make this step conditional or allow it to pass when the contract file is absent.
