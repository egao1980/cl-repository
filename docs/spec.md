# CL Repository OCI Artifact Format Specification

**Version**: 0.3.0

## Overview

A Common Lisp system is distributed as an **OCI Image Index** containing one or more **OCI Image Manifests**. The first manifest is a universal (platform-independent) source distribution. Subsequent manifests are platform-specific overlays containing native libraries, pre-groveled CFFI bindings, and other arch/OS-dependent artifacts.

All artifacts conform to the [OCI Image Specification v1.1](https://github.com/opencontainers/image-spec) and the [OCI Distribution Specification v1.1](https://github.com/opencontainers/distribution-spec). Any OCI-compliant client (oras, crane, skopeo, docker) can pull CL Repository artifacts.

## Artifact Structure

### Image Index (top-level)

```
Image Index
├── Manifest (universal) — no platform field
│   ├── Config blob (application/vnd.common-lisp.system.config.v1+json)
│   ├── Layer: <name>-<version>.tar.gz (OCICL-compatible root dir prefix)
│   └── Layer: docs.tar.gz (optional)
├── Manifest (linux/amd64) — platform overlay (self-contained)
│   ├── Config blob
│   ├── Layer: <name>-<version>.tar.gz (same source blob, deduped by registry)
│   ├── Layer: native-libs.tar.gz (<name>-<version>/native/... prefix)
│   └── Layer: groveler.tar.gz (<name>-<version>/grovel-cache/... prefix)
├── Manifest (darwin/arm64) — platform overlay (self-contained)
│   ├── Config blob
│   ├── Layer: <name>-<version>.tar.gz (same source blob, deduped by registry)
│   └── Layer: native-libs.tar.gz (<name>-<version>/native/... prefix)
└── ...
```

### Media Types

| Type | Value |
|------|-------|
| Image Index | `application/vnd.oci.image.index.v1+json` |
| Image Manifest | `application/vnd.oci.image.manifest.v1+json` |
| Config blob | `application/vnd.common-lisp.system.config.v1+json` |
| Layers | `application/vnd.oci.image.layer.v1.tar+gzip` |
| Artifact type | `application/vnd.common-lisp.system.v1` |
| Namespace root | `application/vnd.common-lisp.namespace-root.v1` |
| System-name anchor | `application/vnd.common-lisp.system-name.v1` |
| System-name config | `application/vnd.common-lisp.system-name.config.v1+json` |
| Empty config | `application/vnd.oci.empty.v1+json` |

### Manifest `artifactType`

Every manifest in the index MUST set `artifactType` to `application/vnd.common-lisp.system.v1`.

### Source Layer Tarball Format (OCICL-compatible)

Source layers use a root directory prefix matching the OCICL convention: `<name>-<version>/`. This ensures:

1. **OCICL client compatibility** — OCICL extracts to a temp dir and expects a single subdirectory
2. **Clean `oras pull` UX** — layer annotation title is `<name>-<version>.tar.gz`, and `tar -xzf` produces a self-contained directory
3. **Standard OCI behavior** — any OCI client can pull and extract without cl-repo

The cl-repo client strips this prefix during installation, producing a flat directory under `systems/<name>/<version>/`.

Overlay layers use the same `<name>-<version>/` root prefix with role-specific subdirectories (e.g., `<name>-<version>/native/libfoo.so`). This makes all layers true overlays: a standard OCI client can extract them in order and files land in the correct layout. The cl-repo client strips the prefix during installation, same as source layers.

## Cross-Repo Blob Mounting for Multi-System Packages

When a package provides multiple system names (e.g., `cffi` provides `cffi`, `cffi-toolchain`, `cffi-libffi`), each system name gets its own OCI repository containing the **full package**. This uses OCI cross-repo blob mounting for zero-copy sharing.

### Registry Layout

```
<ns>/cffi/                    ← primary repo (full push)
  tags: 0.24.1
  blobs: sha256:aaa (source), sha256:bbb (config), ...

<ns>/cffi-toolchain/          ← secondary repo (mounted blobs)
  tags: 0.24.1
  blobs: sha256:aaa (mounted), sha256:bbb (mounted), ...

<ns>/cffi-libffi/             ← secondary repo (mounted blobs)
  tags: 0.24.1
  blobs: sha256:aaa (mounted), sha256:bbb (mounted), ...
```

All secondary repos contain identical content to the primary. External OCI clients get the same result pulling from any repo:

```bash
oras pull registry/cl-systems/cffi-toolchain:0.24.1  # full package
oras pull registry/cl-systems/cffi:0.24.1             # identical content
```

### Publish Flow

1. Push all blobs and manifests to primary repo `<ns>/<canonical-name>:<version>`
2. For each secondary system name: mount all blobs via `POST /v2/<target>/blobs/uploads/?mount=<digest>&from=<source>`, then push manifests and image index

## System-Name Anchors and Discovery

### System-Name Anchor

Each system name gets an anchor manifest at `<ns>/<system-name>:latest`:

- `artifactType`: `application/vnd.common-lisp.system-name.v1`
- Config blob: `{"system-name": "cffi-toolchain", "alias-for": "cffi", "version": "0.24.1"}`
- Empty layers
- Annotations: `dev.common-lisp.system.name`, `dev.common-lisp.alias-for`, `org.opencontainers.image.version`

### Provider Referrer

After publishing, a provider referrer is pushed into each system-name repo:

- `subject`: system-name anchor digest
- `artifactType`: `application/vnd.common-lisp.system.v1`
- Annotations: package name, version, provides, depends-on

Referrers are discoverable via `GET /v2/<ns>/<system-name>/referrers/<anchor-digest>`.

## Project Catalog Root

A per-project catalog root anchor at `<ns>/catalog:latest` provides a catalog of all published systems:

- `artifactType`: `application/vnd.common-lisp.namespace-root.v1`
- Empty config, empty layers

Each published system pushes a catalog referrer into `catalog`:

- `subject`: root anchor digest
- Annotations: `dev.common-lisp.system.name`, `org.opencontainers.image.version`

Browse catalog: `GET /v2/<ns>/catalog/referrers/<root-digest>`

## Layer Roles

Each layer serves a specific role, identified via the config blob's `layer-roles` mapping.

| Role | Contents | When |
|------|----------|------|
| `source` | CL source, .asd files | Always (universal manifest) |
| `native-library` | Prebuilt .so/.dylib/.dll | Platform overlay |
| `static-library` | Prebuilt .a/.lib for CFFI static linking | Platform overlay |
| `cffi-grovel-output` | Pre-groveled .cffi.lisp files | Platform overlay (os+arch+os-version) |
| `cffi-wrapper` | Compiled wrapper .so for inline C | Platform overlay |
| `headers` | C header files | Platform overlay or universal |
| `documentation` | Docs, man pages | Universal (optional) |
| `build-script` | Makefile/build.sh | Universal (fallback) |
| `<custom-role>` | Project-specific payloads | Overlay or universal (author-defined) |

Known roles have conventional extraction locations (`native/`, `grovel-cache/`, etc). Unknown/custom roles are extracted as-is from tar paths (defaulting to package root unless the overlay layer sets a custom prefix).

### Grovel Output Portability

CFFI grovel output (`.cffi.lisp`) is **architecture+OS+OS-version dependent but CL-implementation-independent**. Grovel output derives struct layouts, constants, and type sizes from system headers, which vary across OS versions (e.g., glibc 2.31 vs 2.39, macOS SDK 14 vs 15). A single grovel overlay per os/arch/os-version tuple serves all CL implementations on that platform. When `platform.os.version` is not set on an overlay, it is treated as a generic fallback for that os/arch pair.

## Config Blob Schema

The config blob is a JSON object with media type `application/vnd.common-lisp.system.config.v1+json`.

```json
{
  "system-name": "cffi",
  "version": "0.24.1",
  "depends-on": ["alexandria", {"name": "babel", "version": "0.5"}, "trivial-features"],
  "provides": ["cffi", "cffi-toolchain", "cffi-libffi"],
  "layer-roles": {
    "sha256:abc...": "source",
    "sha256:def...": "native-library",
    "sha256:ghi...": "cffi-grovel-output"
  },
  "cffi-libraries": {
    "libcffi": {
      "define-foreign-library": "cffi::libffi",
      "canary": "ffi_call",
      "search-path": "native/"
    }
  },
  "grovel-systems": ["cffi/grovel-specs"],
  "build-requires": {
    "headers": ["libffi-dev"],
    "tools": ["cc"]
  }
}
```

### Required Fields

- `system-name` (string): Primary ASDF system name.

### Optional Fields

- `version` (string): System version.
- `depends-on` (array): ASDF system dependencies. Each element is either a string (plain dep) or `{"name": "pkg", "version": "ver"}` (versioned constraint).
- `provides` (array of string): ASDF system names provided by this package.
- `layer-roles` (object): Maps layer digest strings to role strings (see Layer Roles).
- `cffi-libraries` (object): Maps foreign library names to metadata objects.
- `grovel-systems` (array of string): ASDF systems containing grovel-file components.
- `build-requires` (object): System-level build requirements. Keys: `headers` (array), `tools` (array).

### Version Constraints in Dependencies

Dependencies with version constraints are serialized as objects:

```json
{"name": "babel", "version": "0.5"}
```

The version string is interpreted as a minimum version using `asdf:version-satisfies` (prefix matching). Plain string dependencies have no version constraint.

## Annotations

### Standard OCI Annotations

Used on both the Image Index and individual manifest descriptors:

| Key | Description |
|-----|-------------|
| `org.opencontainers.image.title` | System name |
| `org.opencontainers.image.version` | Version string |
| `org.opencontainers.image.licenses` | SPDX license identifier |
| `org.opencontainers.image.description` | Short description |
| `org.opencontainers.image.authors` | Author(s) |
| `org.opencontainers.image.created` | ISO 8601 timestamp |
| `org.opencontainers.image.source` | Source repository URL |

### CL-Specific Annotations

| Key | Description | Example |
|-----|-------------|---------|
| `dev.common-lisp.implementation` | Target CL implementation | `sbcl` |
| `dev.common-lisp.implementation.version` | Version constraint | `>=2.0.0` |
| `dev.common-lisp.features` | Required `*features*` keywords | `:sb-thread,:sb-unicode` |
| `dev.common-lisp.layer.roles` | Comma-separated layer roles | `native-library,cffi-grovel-output` |
| `dev.common-lisp.has-native-deps` | Native deps flag | `true` |
| `dev.common-lisp.cffi-libraries` | Foreign library names | `libfoo,libbar` |
| `dev.common-lisp.system.name` | Primary system name | `cffi` |
| `dev.common-lisp.system.depends-on` | Flat comma-separated deps | `alexandria,babel` |
| `dev.common-lisp.system.depends-on.versioned` | Deps with version constraints | `alexandria,babel@>=0.5,cffi` |
| `dev.common-lisp.system.provides` | Provided system names | `cffi,cffi-toolchain` |
| `dev.common-lisp.alias-for` | Canonical system name (on anchors) | `cffi` |

## Client Resolution Algorithm

### System Installation

1. Try direct pull: `GET <ns>/<system-name>/manifests/<version>`
2. If result is an image-index: install directly (full package)
3. If pulled `:latest` and result is a system-name anchor:
   - a. Try Referrers API: `GET /v2/<ns>/<system-name>/referrers/<anchor-digest>?artifactType=application/vnd.common-lisp.system.v1`
   - b. If referrers found: filter by version constraints, pick latest
   - c. If empty/404: read anchor config `alias-for`, install `<ns>/<alias-for>:<version>`

### Dependency Resolution (SAT-based)

The client uses a pure CL SAT solver for transitive dependency resolution:

1. **Scan installed systems**: Build `{name -> version}` map of local installations
2. **Gather universe**: BFS from root, fetch config blobs for reachable packages, enumerate available versions
3. **Build formula**: Variables = `<pkg>-v<ver>` pairs. Constraints = root (must be true), implications (deps), mutual exclusion (one version per package), pins (installed systems)
4. **Solve**: SAT solver with latest-version heuristic returns an assignment
5. **Extract plan**: Filter true bindings, exclude already-installed

Installed systems are pinned as ground truths unless `:force t` is passed.

### Install Deduplication

- **Canonical name + symlinks**: Install to `systems/<config.system-name>/<version>/`, create symlinks for secondary provided names
- **Digest cache**: `systems/.digest-cache.sexp` maps manifest digests to install paths
- **Per-install ASDF refresh**: `configure-asdf-source-registry` after each install so symlinked systems are immediately visible

## Extracted Directory Structure

After installation:

```
~/.local/share/cl-repository/systems/
  cffi/0.24.1/                    ← canonical install
    cffi.asd
    src/...
    native/
    cl-repo-init.lisp
  cffi-toolchain -> cffi           ← symlink
  cffi-libffi -> cffi              ← symlink
  .digest-cache.sexp               ← digest dedup cache
```

### Post-Install Integration

For systems with native dependencies, `cl-repo-init.lisp` is generated:

```lisp
(when (find-package :cffi)
  (pushnew #p"<system-root>/native/"
           (symbol-value (find-symbol "*FOREIGN-LIBRARY-DIRECTORIES*" :cffi))
           :test #'equal))
```

The ASDF source registry includes the systems tree:

```lisp
(asdf:initialize-source-registry
  '(:source-registry
    (:tree (:home ".local/share/cl-repository/systems/"))
    :inherit-configuration))
```

## Platform Selection

### Universal Manifest

The first manifest in the Image Index MUST NOT have a `platform` field. It contains the CL source code and is usable on any platform by any OCI client.

### Platform Overlay Manifests

Subsequent manifests use the standard OCI `platform` field on their descriptor in the index. Each overlay manifest SHOULD include the universal source layer as its first layer, followed by platform-specific layers. This makes each overlay self-contained: a standard OCI client (`oras pull --platform linux/amd64`) retrieves a complete artifact in one pull. The source layer blob is content-addressable, so the registry stores it only once regardless of how many overlays reference it.

The cl-repo installer skips source-role layers when extracting overlays (they are already extracted from the universal manifest).

### Resolution Algorithm

1. Pull the Image Index.
2. Detect local platform via `trivial-features`.
3. **Always** select the universal manifest (no `platform` field).
4. Match overlay descriptors by `platform.os` + `platform.architecture`. Prefer overlays that also match `platform.os.version` when set; fall back to overlays without `os.version` (generic fallback).
5. If `dev.common-lisp.implementation` annotation is present, match against the running CL.
6. Pull and extract all matched manifests.

### Build Matrix Dimensions

| Dimension | Example Values | When Needed |
|-----------|---------------|-------------|
| OS | linux, darwin, windows | Always for platform overlays |
| Architecture | amd64, arm64, 386 | Always for platform overlays |
| CL Implementation | sbcl, ccl, ecl | Only for impl-specific compiled code |
| OS Version | ubuntu-20.04, macos-14 | For ABI-sensitive native libs and grovel output |

## Lockfile Format

`cl-repo.lock` uses S-expression format:

```lisp
;;; cl-repo.lock -- auto-generated, do not edit
((:system "cffi" :version "0.24.1"
  :index-digest "sha256:aaa..."
  :source-digest "sha256:bbb..."
  :overlay-digest "sha256:ccc..."
  :registry "ghcr.io/cl-systems")
 (:system "alexandria" :version "1.4"
  :index-digest "sha256:ddd..."
  :source-digest "sha256:eee..."
  :registry "ghcr.io/cl-systems"))
```

## Registry Naming Convention

Systems are pushed to registries using the naming pattern:

```
<registry>/<namespace>/<system-name>:<version>
```

Examples:
- `ghcr.io/cl-systems/alexandria:1.4`
- `ghcr.io/cl-systems/cffi:0.24.1`
- `localhost:5050/cl-systems/bordeaux-threads:0.9.4`

## ASDF Embedded Configuration

OCI packaging metadata can be embedded directly in a `.asd` file using ASDF's `:properties` plist.

### Format

```lisp
(defsystem "my-lib"
  :version "2.0.0"
  :depends-on ("alexandria" (:version "cffi" "0.24"))
  :properties (:cl-repo (:cffi-libraries ("libfoo")
                          :provides ("my-lib" "my-lib/utils")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :layers ((:role "native-library"
                                                :files (("lib/linux-amd64/libfoo.so" . "libfoo.so")))
                                               (:role "cffi-grovel-output"
                                                :files (("grovel/linux-amd64/libfoo.cffi.lisp"
                                                         . "libfoo.cffi.lisp")))))
                                     (:platform (:os "linux" :arch "amd64" :os-version "ubuntu-22.04")
                                      :layers ((:role "native-library"
                                                :files (("lib/linux-amd64-u2204/libfoo.so"
                                                         . "libfoo.so")))))))))
```

` :layers` is the recommended schema. Legacy `:native-paths` is still accepted and normalized to one `native-library` layer for backward compatibility.

### Provides Resolution

1. Explicit `:cl-repo :provides` from `.asd` `:properties`
2. Auto-discovered from `*.asd` files in source directory
3. Fallback: `(list system-name)`

### Field Resolution

| Field | Source |
|-------|--------|
| `name` | `asdf:component-name` |
| `version` | `asdf:component-version` |
| `depends-on` | `asdf:system-depends-on` (preserves version constraints) |
| `provides` | `:cl-repo :provides` or auto-detected or fallback |
| `cffi-libraries` | `:cl-repo :cffi-libraries` |
| `overlays` | `:cl-repo :overlays` |

## Compatibility

- **Standard OCI clients**: Each overlay manifest is self-contained (source + native layers). `oras pull --platform linux/amd64 ghcr.io/ns/pkg:1.0` retrieves all layers for that platform in a single pull. The universal manifest (no platform) serves pure-Lisp clients. No cl-repo-specific tooling is required to download and extract a package.
- **Backward compatibility**: Pure-Lisp systems require only a single universal manifest.
- **CFFI integration**: Pre-groveled output and native libraries are additive overlays. Systems always remain buildable from source as a fallback.
- **Content-addressable dedup**: Overlay manifests reference the same source layer blob as the universal manifest. OCI registries store the blob once; overlay manifests just add a descriptor pointing to it.
