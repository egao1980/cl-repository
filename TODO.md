# CL Repository — Roadmap

Planned features and future work, roughly ordered by priority.

## 1. License Governance

The spec already carries SPDX license identifiers via `org.opencontainers.image.licenses` annotations (see [spec.md](docs/spec.md)). This track extends that foundation into actionable tooling.

- [ ] **SPDX validation at publish time** — reject artifacts with missing or invalid SPDX license identifiers
- [ ] **License compatibility engine** — given a resolved dependency tree, verify that transitive licenses are compatible (e.g. GPL propagation into MIT-licensed dependents)
- [ ] **Policy file** — `cl-repo-policy.sexp` (or `.cl-repo/policy.sexp`) allowing users/orgs to whitelist or blacklist license families (e.g. "no AGPL", "only OSI-approved")
- [ ] **CLI surface** — `cl-repo install --check-licenses`, `cl-repo audit licenses`
- [ ] **Lockfile integration** — record resolved SPDX license per dependency in `cl-repo.lock`

## 2. Package Signing & Verification

Leverage standard OCI signing infrastructure rather than inventing a custom scheme.

- [ ] **Cosign signing at publish time** — integrate `cosign sign` (Sigstore keyless or key-pair) into `cl-repo publish` flow
- [ ] **Verification on install** — `cosign verify` before extracting; fail-closed when policy requires signatures
- [ ] **OCI 1.1 Referrers API** — attach signatures as referrer artifacts (the project already uses Referrers for system-name anchors and catalog entries)
- [ ] **Trust policy config** — define which signing identities / OIDC issuers to accept (`cl-repo-trust-policy.sexp` or similar)
- [ ] **Notation (CNCF Notary v2)** — alternative signer for on-prem / air-gapped registries
- [ ] **Registry support matrix** — document which registries support what (GHCR → cosign, Harbor → Notation, etc.)
