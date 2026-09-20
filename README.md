# Nudge

Nudge is a Rails commerce application built as a modular monolith. Docker Compose is the canonical local development and test environment; Ruby and PostgreSQL do not need to be installed on the host.

## Local development

```bash
docker compose build app
docker compose run --rm app bin/setup --skip-server
docker compose up app
```

Open <http://localhost:3000/up> to verify that Rails is healthy.

## Checks

```bash
docker compose run --rm -e RAILS_ENV=test app bin/rails db:prepare test
docker compose run --rm app bin/rubocop
docker compose run --rm app bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
docker compose run --rm app bin/bundler-audit
```

Normal teardown preserves the database:

```bash
docker compose down
```

Deleting local database volumes is intentionally explicit and destructive:

```bash
docker compose down --volumes
```

External providers remain in fixture or sandbox mode during ordinary development and CI.
