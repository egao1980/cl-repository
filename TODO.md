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

## 3. SBOM Generation ([CycloneDX](https://cyclonedx.org/))

Generate a Software Bill of Materials for installed dependency trees. [CycloneDX](https://github.com/CycloneDX) (ECMA-424) is the target format — it has the most advanced license support of any SBOM standard and covers SBOM, VEX, and supply-chain attestations in one spec. Key references: [specification](https://github.com/CycloneDX/specification), [cyclonedx-cli](https://github.com/CycloneDX/cyclonedx-cli) (validation/merge/diff/convert).

- [ ] **CycloneDX SBOM export** — `cl-repo sbom` generates a CycloneDX BOM (JSON) from `cl-repo.lock` and installed system metadata
- [ ] **Component mapping** — map OCI config blob fields (`system-name`, `version`, `depends-on`, SPDX license annotation) to CycloneDX `component` entries with `purl` identifiers (`pkg:oci/...` or a custom `pkg:cl-repo/...` scheme)
- [ ] **Dependency graph** — emit the full transitive dependency tree in CycloneDX `dependencies` section
- [ ] **VEX integration** — attach Vulnerability Exploitability Exchange data when available (e.g. from registry-side scanners)
- [ ] **OCI artifact attachment** — publish SBOM as an OCI referrer artifact (media type `application/vnd.cyclonedx+json`) linked to the package manifest via Referrers API
- [ ] **CI pipeline** — generate and attach SBOM automatically during `cl-repo publish`
