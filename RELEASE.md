# v0.1.0 — Initial Release

OCI-based distribution system for Common Lisp packages. Packages are standard OCI artifacts pushable to any OCI-compliant registry (GHCR, Docker Hub, Quay, etc.) and pullable by any OCI client or the included CL-native client.

## Highlights

- **OCI Image Spec v1.1** — CL systems are distributed as OCI Image Indexes with universal source manifests and platform-specific overlay manifests for native dependencies.
- **Works with any OCI registry** — GHCR, Docker Hub, Quay, or a self-hosted `registry:2`.
- **Interoperable** — artifacts are pullable by `oras`, `crane`, `skopeo`, `docker`, or the included CL client.

## Systems

| System | Description |
|--------|-------------|
| **cl-oci** | CLOS data model for OCI Image and Distribution specifications |
| **cl-oci-client** | OCI Distribution Spec v1.1 HTTP client (push/pull blobs, manifests, tags) |
| **cl-repository-packager** | ASDF plugin + build matrix for packaging CL systems as OCI artifacts |
| **cl-repository-client** | Client library + Roswell CLI for installing packages from OCI registries |
| **cl-repository-ql-exporter** | Quicklisp/Ultralisp to OCI artifact bulk exporter |

## Features

### OCI Artifact Format (`docs/spec.md`)

- Custom artifact type: `application/vnd.common-lisp.system.v1`
- Config blob schema with system metadata, dependency graph, CFFI library descriptors, and layer role mapping
- `dev.common-lisp.*` annotation namespace for CL-specific metadata on manifest descriptors
- Universal manifest (pure CL source, platform-independent) + platform overlay manifests (native libs, pre-groveled CFFI output)
- Lockfile format (`cl-repo.lock`) for reproducible installs

### Packaging (`cl-repository-packager`)

- `package-op` ASDF operation — build and push in one step
- Embedded OCI config in `.asd` via `:properties :cl-repo` plist
- Automatic field resolution from ASDF system metadata (name, version, description, author, license, depends-on)
- Build matrix: OS × architecture × (optionally) CL implementation
- Layer roles: `source`, `native-library`, `static-library`, `cffi-grovel-output`, `cffi-wrapper`, `headers`, `documentation`, `build-script`

### Client (`cl-repository-client`)

- `cl-repo:load-system` — pull and load a system from configured OCI registries
- `cl-repo:add-registry` — configure registries with namespace prefixes
- Platform resolution via `trivial-features` (`*features*` keywords)
- Automatic CFFI foreign library directory setup on install
- ASDF source registry integration (`~/.local/share/cl-repository/systems/`)

### CLI (`roswell/cl-repo.ros`)

- `cl-repo install <system>[:<version>]`
- `cl-repo publish`
- `cl-repo ql-export <dist-url> --registry <host> --namespace <ns>`

### Quicklisp Exporter (`cl-repository-ql-exporter`)

- Parse Quicklisp/Ultralisp distribution metadata
- Bulk-convert Quicklisp systems to OCI artifacts
- Push to any OCI-compliant registry

### OCI Client (`cl-oci-client`)

- Full OCI Distribution Spec v1.1 HTTP client
- Blob upload (monolithic + chunked), manifest push/pull, tag listing
- Token-based authentication (Bearer + Basic)

### CI/CD

- GitHub Actions workflow for running tests
- GitHub Actions workflow for publishing to OCI registry

## Examples

Six worked examples covering basic usage, publishing, Quicklisp mirroring, native dependencies, CI/CD workflows, and embedded `.asd` configuration.

## Stats

- 38 source files, 23 test files
- 5 ASDF systems + 1 integration test system
- Spec version: 0.1.0

## Requirements

- [SBCL](http://www.sbcl.org/) (or another supported CL implementation)
- [Roswell](https://github.com/roswell/roswell) + [qlot](https://github.com/fukamachi/qlot)
- Docker (for integration tests)

## License

MIT
