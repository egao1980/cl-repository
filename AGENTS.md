# CL Repository - Agent Guide

## Project Overview

OCI-based Common Lisp distribution system. Five ASDF systems in a monorepo using `package-inferred-system` convention.

## Architecture

```
cl-oci (CLOS data model) <- cl-oci-client (HTTP) <- cl-repository-packager (build + publish)
                                                  <- cl-repository-client (install + CLI)
                                                  <- cl-repository-ql-exporter (QL -> OCI)
```

## Conventions

- **Package-inferred-system**: each `.lisp` file declares its own `defpackage`, ASDF infers deps from `:import-from` / `:use`.
- **Aggregation**: `all.lisp` per subsystem uses `uiop:define-package` with `:use-reexport`.
- **Constants**: use `alexandria:define-constant` with `:test #'equal` (not `defconstant` for strings — SBCL `DEFCONSTANT-UNEQL`).
- **JSON**: `yason` for encoding/decoding (Quicklisp-native, hash-table-based).
- **Testing**: `rove` framework. Test systems use explicit `:components` (not `package-inferred-system`).
- **Dependencies**: managed via `qlfile` (qlot). Register external packages with `register-system-packages` in `.asd` files.

## Documentation Localization

- Every user-facing documentation file has two localized variants:
  - Russian: `<name>.ru.md`
  - Japanese: `<name>.ja.md`
- When updating any canonical English doc (`README.md`, `docs/**/*.md`), update corresponding `.ru.md` and `.ja.md` files in the same change.
- Keep structure and command examples aligned across language variants.
- If a section is intentionally brief in localized files, explicitly note that and keep links to the canonical English source.

## Key Directories

| Path | Contents |
|------|----------|
| `src/oci/` | Core OCI CLOS classes, serialization |
| `src/oci-client/` | OCI Distribution Spec HTTP client |
| `src/packager/` | ASDF plugin, layer/manifest builders |
| `src/client/` | Install/manage, platform resolver, CLI commands |
| `src/ql-exporter/` | Quicklisp dist parser, repackager, exporter |
| `tests/` | Rove tests per subsystem |
| `roswell/` | `cl-repo.ros` CLI entry point |
| `docs/` | Specification and requirements |

## Building & Testing

```sh
qlot install                          # install deps
qlot exec ros -e '(asdf:load-system "cl-oci")'  # load a system
qlot exec ros -e '(asdf:test-system "cl-oci")'  # run tests
```

## Local CI Testing (Docker + act)

Use Docker and `act` to execute GitHub Actions workflows locally.

Quickstart:

```sh
docker rm -f oci-registry 2>/dev/null || true
docker run -d --name oci-registry -p 5050:5000 registry:2
act -W .github/workflows/test.yml -j test -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
act -W .github/workflows/test.yml -j integration -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

Full tutorial (including local publish/tag simulation): `docs/tutorial-local-testing-docker-act.md`.

## OCI Artifact Format

CL packages are OCI Image Indexes: universal source manifest + platform-specific overlay manifests. Config blob media type: `application/vnd.common-lisp.system.config.v1+json`. Artifact type: `application/vnd.common-lisp.system.v1`. See `docs/spec.md` for full specification.
