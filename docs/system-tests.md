# Browser system tests

The browser test lane renders the application in a real headless Chromium browser. It verifies the application shell at 320, 375, 768, and 1280 CSS pixels, including landmarks, horizontal overflow, keyboard access to the skip link, visible focus, and 44-by-44-pixel minimum target geometry.

Run the lane from the repository root:

```sh
docker compose -p nudge-system-test -f compose.yaml -f compose.system-test.yaml run --rm --build system_tests
mkdir -p tmp/system-test-artifacts
HOST_UID="$(id -u)" HOST_GID="$(id -g)" docker compose -p nudge-system-test -f compose.yaml -f compose.system-test.yaml --profile tools run --rm --no-deps artifact_export
docker compose -p nudge-system-test -f compose.yaml -f compose.system-test.yaml down
```

The separate Compose override starts PostgreSQL, the Rails test server, and Selenium only for this lane. It removes the development database's inherited host port, uses a project-scoped test database volume, and publishes no application or WebDriver ports. Compose waits for service health checks, the Rails test server prepares the test database and compiled stylesheet, and every application process sets both provider modes to `fixture`.

The Rails server and runner use UID/GID 1000 with `no-new-privileges`. Their repository bind is read-only, so a checkout owned by another host UID remains usable without changing its ownership. Named volumes provide the writable Rails runtime paths, compiled assets, coverage, and failure screenshots. The optional exporter reads those volumes and writes `tmp/system-test-artifacts` as `HOST_UID:HOST_GID`; create that destination as the host user before exporting. Docker Desktop users can omit `HOST_UID` and `HOST_GID` and use the defaults shown in the Compose file.

The Selenium image is pinned to the multi-platform manifest for the official `seleniumhq/standalone-chromium` 4.47.0 release. The browser is limited to one session, two CPUs, 2 GB of memory, and 1 GB of shared memory; its VNC server is disabled.

Failed tests save screenshots in the runner's writable temporary-data volume. The exporter places screenshots and SimpleCov output under `tmp/system-test-artifacts`. The lane owns only read-only shell journeys. Future stateful journeys must create uniquely namespaced test records and clean them up.

`system_tests` runs the shared `bin/test-browser` lane entry point with `RUN_BROWSER_TESTS=1`, so browser registration and fixture-only safeguards stay aligned with the other test lanes.

The CI browser job uses a unique Compose project for each workflow run. It treats the two container-runtime probes and `bin/test-browser` as required gates, then exports and uploads coverage, failure screenshots, and the browser log under `if: always()` before removing the isolated volumes.
