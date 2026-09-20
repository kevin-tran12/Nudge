# Runtime and tool version inventory

| Component | Version | Source of truth |
|---|---:|---|
| Ruby | 4.0.7 | `.ruby-version`, `Dockerfile` |
| Rails | 8.1.3.1 | `Gemfile`, `Gemfile.lock` |
| PostgreSQL | 18 | `compose.yaml` and future Terraform |
| pgvector | 0.8.5 | `compose.yaml` and Cloud SQL extension compatibility |
| Tailwind CSS integration | Locked by Bundler | `Gemfile.lock` |
| Docker Compose | 2.24.4 or newer; verified with 5.4.0 | `compose.yaml`, `compose.system-test.yaml` (`!reset` merge tag) |
| Selenium WebDriver gem | 4.49.0 | `Gemfile.lock` |
| Selenium Grid | 4.47.0-20260808, image-manifest-digest-pinned | `compose.system-test.yaml` |
| Chromium / ChromeDriver | 151.0.7922.108 | `compose.system-test.yaml` |
| GitHub checkout action | 7.0.1, commit-pinned | `.github/workflows/ci.yml` |
| Trivy | 0.74.0, image-digest-pinned | `.github/workflows/ci.yml` |

Update this inventory together with manifests, lockfiles, container references, and compatibility tests.
