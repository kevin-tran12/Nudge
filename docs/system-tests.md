# Browser system tests

The browser test lane renders the application in a real headless Chromium browser. It verifies the application shell at 320, 375, 768, and 1280 CSS pixels, including landmarks, horizontal overflow, keyboard access to the skip link, visible focus, and 44-by-44-pixel minimum target geometry.

Run the lane from the repository root:

```sh
docker compose -p nudge-system-test -f compose.yaml -f compose.system-test.yaml run --rm --build system_tests
docker compose -p nudge-system-test -f compose.yaml -f compose.system-test.yaml down
```

The separate Compose override starts PostgreSQL, the Rails test server, and Selenium only for this lane. Neither the application nor WebDriver publishes a host port. Compose waits for service health checks, the Rails test server prepares the test database and compiled stylesheet, and every application process sets `PROVIDER_MODE=fixture`.

The Selenium image is pinned to the multi-platform manifest for the official `seleniumhq/standalone-chromium` 4.47.0 release. The browser is limited to one session, two CPUs, 2 GB of memory, and 1 GB of shared memory; its VNC server is disabled.

Failed tests save screenshots under `tmp/screenshots`. The lane owns only read-only shell journeys. Future stateful journeys must create uniquely namespaced test records and clean them up.

After the test-lane package adds `bin/test-browser`, use it as the `system_tests` command with `RUN_BROWSER_TESTS=1`; the Compose services and environment variables remain the same.
