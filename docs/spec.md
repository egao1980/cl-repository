# CL Repository OCI Artifact Format Specification

**Version**: 0.1.0

## Overview

A Common Lisp system is distributed as an **OCI Image Index** containing one or more **OCI Image Manifests**. The first manifest is a universal (platform-independent) source distribution. Subsequent manifests are platform-specific overlays containing native libraries, pre-groveled CFFI bindings, and other arch/OS-dependent artifacts.

All artifacts conform to the [OCI Image Specification v1.1](https://github.com/opencontainers/image-spec) and the [OCI Distribution Specification v1.1](https://github.com/opencontainers/distribution-spec). Any OCI-compliant client (oras, crane, skopeo, docker) can pull CL Repository artifacts.

## Artifact Structure

### Image Index (top-level)

```
Image Index
├── Manifest (universal) — no platform field
│   ├── Config blob (application/vnd.common-lisp.system.config.v1+json)
│   ├── Layer: source.tar.gz
│   └── Layer: docs.tar.gz (optional)
├── Manifest (linux/amd64) — platform overlay
│   ├── Config blob
│   ├── Layer: native-libs.tar.gz
│   └── Layer: groveler.tar.gz
├── Manifest (darwin/arm64) — platform overlay
│   ├── Config blob
│   └── Layer: native-libs.tar.gz
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

### Manifest `artifactType`

Every manifest in the index MUST set `artifactType` to `application/vnd.common-lisp.system.v1`.

## Layer Roles

Each layer serves a specific role, identified via the config blob's `layer-roles` mapping.

| Role | Contents | When |
|------|----------|------|
| `source` | CL source, .asd files | Always (universal manifest) |
| `native-library` | Prebuilt .so/.dylib/.dll | Platform overlay |
| `static-library` | Prebuilt .a/.lib for CFFI static linking | Platform overlay |
| `cffi-grovel-output` | Pre-groveled .cffi.lisp files | Platform overlay (os+arch) |
| `cffi-wrapper` | Compiled wrapper .so for inline C | Platform overlay |
| `headers` | C header files | Platform overlay or universal |
| `documentation` | Docs, man pages | Universal (optional) |
| `build-script` | Makefile/build.sh | Universal (fallback) |

### Grovel Output Portability

CFFI grovel output (`.cffi.lisp`) is **architecture+OS dependent but CL-implementation-independent**. A single grovel overlay per os/arch pair serves all CL implementations on that platform.

## Config Blob Schema

The config blob is a JSON object with media type `application/vnd.common-lisp.system.config.v1+json`.

```json
{
  "system-name": "cffi",
  "version": "0.24.1",
  "depends-on": ["alexandria", "babel", "trivial-features"],
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
- `depends-on` (array of string): ASDF system dependencies.
- `provides` (array of string): ASDF system names provided by this package.
- `layer-roles` (object): Maps layer digest strings to role strings (see Layer Roles).
- `cffi-libraries` (object): Maps foreign library names to metadata objects.
- `grovel-systems` (array of string): ASDF systems containing grovel-file components.
- `build-requires` (object): System-level build requirements. Keys: `headers` (array), `tools` (array).

### CFFI Library Metadata

Each entry in `cffi-libraries` contains:

- `define-foreign-library` (string): Fully qualified symbol of the CFFI foreign library definition.
- `canary` (string): Function name to detect if the library is already loaded.
- `search-path` (string): Relative path (from system root) added to `cffi:*foreign-library-directories*`.

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

Used on platform overlay descriptors within the Image Index:

| Key | Description | Example |
|-----|-------------|---------|
| `dev.common-lisp.implementation` | Target CL implementation | `sbcl` |
| `dev.common-lisp.implementation.version` | Version constraint | `>=2.0.0` |
| `dev.common-lisp.features` | Required `*features*` keywords | `:sb-thread,:sb-unicode` |
| `dev.common-lisp.layer.roles` | Comma-separated layer roles in this manifest | `native-library,cffi-grovel-output` |
| `dev.common-lisp.has-native-deps` | Whether the project has native deps | `true` |
| `dev.common-lisp.cffi-libraries` | Comma-separated foreign library names | `libfoo,libbar` |
| `dev.common-lisp.system.name` | Primary system name | `cffi` |
| `dev.common-lisp.system.depends-on` | Comma-separated dependencies | `alexandria,babel` |
| `dev.common-lisp.system.provides` | Comma-separated provided systems | `cffi,cffi-toolchain` |

## Platform Selection

### Universal Manifest

The first manifest in the Image Index MUST NOT have a `platform` field. It contains the CL source code and is usable on any platform by any OCI client.

### Platform Overlay Manifests

Subsequent manifests use the standard OCI `platform` field on their descriptor in the index:

```json
{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "digest": "sha256:...",
  "size": 1234,
  "platform": {
    "os": "linux",
    "architecture": "amd64"
  },
  "annotations": {
    "dev.common-lisp.implementation": "sbcl",
    "dev.common-lisp.layer.roles": "native-library,cffi-grovel-output"
  }
}
```

### Resolution Algorithm

A CL Repository client resolves manifests as follows:

1. Pull the Image Index.
2. Detect local platform via `trivial-features` (`*features*` keywords: `:linux`, `:darwin`, `:windows`, `:x86-64`, `:arm64`, etc.).
3. **Always** select the universal manifest (no `platform` field).
4. Match overlay descriptors by `platform.os` + `platform.architecture`.
5. If `dev.common-lisp.implementation` annotation is present, match against the running CL implementation.
6. Pull and extract all matched manifests.

### Build Matrix Dimensions

| Dimension | Example Values | When Needed |
|-----------|---------------|-------------|
| OS | linux, darwin, windows | Always for platform overlays |
| Architecture | amd64, arm64, 386 | Always for platform overlays |
| CL Implementation | sbcl, ccl, ecl | Only for impl-specific compiled code |
| OS Version | ubuntu-20.04, macos-14 | For ABI-sensitive native libs |

## Extracted Directory Structure

After installation, the directory is immediately ASDF-loadable:

```
~/.local/share/cl-repository/systems/<name>/<version>/
  <name>.asd              # Original .asd from source layer
  src/...                 # CL source files
  native/                 # From native-library overlay
    libfoo.so
  grovel-cache/           # From cffi-grovel-output overlay
    <system>--<name>.cffi.lisp
  headers/                # From headers overlay
    foo.h
  docs/                   # From documentation layer
    manual.html
  cl-repo-init.lisp       # Auto-generated CFFI integration (if applicable)
```

### Post-Install Integration

For systems with native dependencies, `cl-repo-init.lisp` is generated:

```lisp
;; Push native library directory to CFFI search path
(when (find-package :cffi)
  (pushnew #p"<system-root>/native/"
           (symbol-value (find-symbol "*FOREIGN-LIBRARY-DIRECTORIES*" :cffi))
           :test #'equal))
```

The ASDF source registry is configured to include the systems tree:

```lisp
(asdf:initialize-source-registry
  '(:source-registry
    (:tree (:home ".local/share/cl-repository/systems/"))
    :inherit-configuration))
```

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
<registry>/<namespace>/<project-name>:<version>
```

Examples:
- `ghcr.io/cl-systems/alexandria:1.4`
- `ghcr.io/cl-systems/cffi:0.24.1`
- `localhost:5050/cl-systems/bordeaux-threads:0.9.4`

## ASDF Embedded Configuration

OCI packaging metadata can be embedded directly in a `.asd` file using ASDF's `:properties` plist. The packager's `auto-package-spec` reads the `:cl-repo` key and merges it with standard ASDF system fields.

### Format

```lisp
(defsystem "my-lib"
  :version "2.0.0"
  :description "A library with native deps"
  :author "Author"
  :license "MIT"
  :depends-on ("alexandria" "cffi")
  :properties (:cl-repo (:cffi-libraries ("libfoo")
                          :provides ("my-lib" "my-lib/utils")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :native-paths ("lib/linux-amd64/libfoo.so"))
                                     (:platform (:os "darwin" :arch "arm64")
                                      :native-paths ("lib/darwin-arm64/libfoo.dylib")))))
  :components (...))
```

### Supported `:cl-repo` Keys

| Key | Type | Description |
|-----|------|-------------|
| `:cffi-libraries` | list of strings | Foreign library names used by CFFI |
| `:provides` | list of strings | ASDF system names this package provides (defaults to the system name) |
| `:overlays` | list of plists | Platform-specific overlay specifications |

### Overlay Plist Format

```lisp
(:platform (:os "linux" :arch "amd64" :lisp "sbcl")  ; :lisp is optional
 :native-paths ("path/to/lib.so" ...)
 :run-groveler t                                       ; optional, run CFFI groveler
 :cffi-wrapper-systems ("my-wrapper-system"))           ; optional
```

### Field Resolution

`auto-package-spec` merges fields from two sources:

| Field | Source |
|-------|--------|
| `name` | `asdf:component-name` |
| `version` | `asdf:component-version` |
| `description` | `asdf:system-description` |
| `author` | `asdf:system-author` |
| `license` | `asdf:system-licence` |
| `depends-on` | `asdf:system-depends-on` |
| `source-dir` | `asdf:system-source-directory` |
| `provides` | `:cl-repo :provides` (fallback: system name) |
| `cffi-libraries` | `:cl-repo :cffi-libraries` |
| `overlays` | `:cl-repo :overlays` |

## Compatibility

- **OCI clients**: Any OCI-compliant tool can pull these artifacts. Without platform selection, the universal source manifest is returned.
- **Backward compatibility**: The format is designed so pure-Lisp systems (no native deps) require only a single universal manifest, which is a valid OCI artifact usable by any tool.
- **CFFI integration**: Pre-groveled output and native libraries are additive overlays. Systems always remain buildable from source as a fallback.
