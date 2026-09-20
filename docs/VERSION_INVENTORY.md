# Runtime and tool version inventory

| Component | Version | Source of truth |
|---|---:|---|
| Ruby | 4.0.7 | `.ruby-version`, `Dockerfile` |
| Rails | 8.1.3.1 | `Gemfile`, `Gemfile.lock` |
| PostgreSQL | 18 | `compose.yaml` and future Terraform |
| pgvector | 0.8.5 | `compose.yaml` and Cloud SQL extension compatibility |
| Tailwind CSS integration | Locked by Bundler | `Gemfile.lock` |
| Docker Compose | Compose specification | `compose.yaml` |
| GitHub checkout action | 7.0.1, commit-pinned | `.github/workflows/ci.yml` |
| Trivy | 0.74.0, image-digest-pinned | `.github/workflows/ci.yml` |

Update this inventory together with manifests, lockfiles, container references, and compatibility tests.
