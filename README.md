# Nudge

Nudge is a Rails commerce application built as a modular monolith. Docker Compose is the canonical local development and test environment; Ruby and PostgreSQL do not need to be installed on the host.

## Local development

```bash
docker compose build app
docker compose run --rm app bin/setup --skip-server
docker compose up --wait app
```

Open <http://localhost:3000/up> for liveness. Readiness, including the database connection, is available at <http://localhost:3000/health/ready>. Both endpoints return only a fixed status and never include configuration or dependency details.

## Checks

```bash
docker compose run --rm -e RAILS_ENV=test app bin/rails db:prepare
docker compose run --rm -e RAILS_ENV=test app bin/rails test
docker compose run --rm app bin/rubocop
docker compose run --rm app bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
docker compose run --rm app bin/bundler-audit
```

The development image and Compose service run as UID/GID `1000:1000`. Writable runtime directories use named volumes layered beneath the source bind mount, keeping source reloads portable across Docker Desktop and Linux without a root Rails process. Provider modes are fixed to fixtures for ordinary development and tests; the entrypoint refuses a non-fixture override.

Development starts through `bin/dev`, which removes only the generated `public/assets/.manifest.json` before Rails boots. This prevents an earlier precompile from hiding current CSS. The existing Puma Tailwind plugin builds and watches CSS in the retained asset volume. Production continues to use its precompiled manifest.

Check development asset refresh, restart, and watcher shutdown without a database:

```bash
docker compose run --rm --no-deps app ruby test/runtime/development_assets_contract.rb
```

Inspect logs without entering the container:

```bash
docker compose logs app
```

Build and smoke-test the production-compatible runtime image:

```bash
docker build --target runtime --tag nudge:runtime .
docker run --rm --env SECRET_KEY_BASE_DUMMY=1 nudge:runtime ruby test/runtime/production_image_contract.rb
```

The repository separates quick tests from integration/contracts and enforces full-suite coverage. See [Testing and CI](docs/TESTING.md) for the lane commands, coverage floor, fixture guardrails, artifacts, and current browser-E2E status.

Normal teardown preserves the database:

```bash
docker compose down
```

Deleting local database volumes is intentionally explicit and destructive:

```bash
docker compose down --volumes
```

External providers remain in fixture or sandbox mode during ordinary development and CI.
