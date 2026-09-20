# Security policy

## Reporting a vulnerability

Do not disclose suspected vulnerabilities in public issues, discussions, pull
requests, logs, or planning documents.

Use GitHub's **Security > Report a vulnerability** flow for this repository.
Include the affected component, reproduction steps, potential impact, and any
known mitigations. Do not include real customer data, credentials, payment
details, or other secrets in the report.

## Secrets

Never commit real credentials. Local environment files, Rails master keys,
Terraform variable files, `tfsecrets`, cloud service-account files, and private
keys are ignored. Commit only sanitized `*.example` templates that contain
placeholder values.
