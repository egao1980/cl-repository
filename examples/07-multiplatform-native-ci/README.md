# Multiplatform Native CI

Build and publish a CFFI-based Common Lisp system with platform-specific native library overlays from GitHub Actions.

This example includes a real C library (`libcalc`), CFFI grovel bindings (`cl-calc`), and two CI workflow patterns.

## Project Structure

```
libcalc/
  calc.h              # Public C API: calc_result struct, calc_add(), calc_version()
  calc.c              # Implementation
  Makefile            # Builds libcalc.so (linux) or libcalc.dylib (darwin)

cl-calc/
  cl-calc.asd         # ASDF system with :properties :cl-repo overlay config
  package.lisp        # defpackage :cl-calc
  grovel.lisp         # CFFI grovel: CALC_MAX_VALUE constant, calc_result struct layout
  bindings.lisp       # CFFI defcfun: calc-add, calc-version
```

## Resulting OCI Image Index

Each overlay manifest is self-contained: it includes the source layer (same content-addressable blob as the universal manifest, stored once by the registry) plus platform-specific native library layers. This means `oras pull --platform linux/amd64` gives you a complete package in one pull.

```
Image Index (cl-calc:1.0.0)
  +-- Manifest (universal)       -> source layer
  +-- Manifest (linux/amd64)     -> source layer + libcalc.so
  +-- Manifest (linux/arm64)     -> source layer + libcalc.so
  +-- Manifest (darwin/arm64)    -> source layer + libcalc.dylib
  +-- Manifest (darwin/amd64)    -> source layer + libcalc.dylib
```

## CI Patterns

### Pattern 1: Parallel Batch Publish (`parallel-publish.yml`)

All platforms build concurrently, upload artifacts, then a single job publishes the complete index.

```
build (matrix)           publish
  linux/amd64  ──┐
  linux/arm64  ──┤──> collect all ──> build-package ──> publish-package ──> GHCR
  darwin/arm64 ──┤
  darwin/amd64 ──┘
```

**When to use:** You want an atomic tag -- consumers never see a partial index. Good when all target platforms are available as GH runners.

### Pattern 2: Incremental Overlays (`incremental-overlay.yml`)

Source is published first, then each platform adds its overlay independently.

```
publish-source ──> GHCR (1 manifest)
  |
  +── overlay linux/amd64  ──> GHCR (2 manifests)
  +── overlay linux/arm64  ──> GHCR (3 manifests)
  +── overlay darwin/arm64 ──> GHCR (4 manifests)
  +── overlay darwin/amd64 ──> GHCR (5 manifests)
```

**When to use:** Platforms are added over time (e.g., new arch support), builds happen on self-hosted runners, or you want to add overlays without re-publishing source. Uses `max-parallel: 1` to serialize index updates.

### Choosing Between Them

| Concern | Parallel Batch | Incremental |
|---------|---------------|-------------|
| Atomicity | Tag is complete from the start | Tag grows as overlays arrive |
| Runner flexibility | Need artifact upload/download | Each runner publishes directly |
| Adding platforms later | Must re-publish everything | Just run add-overlay |
| Complexity | More Lisp code in publish job | Simpler per-runner logic |
| Concurrency safety | N/A (single publisher) | Needs serialization |

## Build Matrix Dimensions

| Dimension | Example Values | When Needed |
|-----------|---------------|-------------|
| OS | linux, darwin, windows | Always for platform overlays |
| Architecture | amd64, arm64 | Always for platform overlays |
| OS Version | ubuntu-22.04, macos-14 | ABI-sensitive native libs (glibc, SDK) |
| CL Implementation | sbcl, ccl, ecl | Only for impl-specific compiled code |

Most CFFI-based packages only need OS + Architecture. OS Version is for cases where the native library links against version-specific system libraries (e.g., glibc 2.31 vs 2.39). CL Implementation is rarely needed since grovel output is implementation-independent.

## Running Locally

Build libcalc and test with a local OCI registry:

```sh
# Start a local registry
docker run -d -p 5050:5000 --name oci-registry registry:2

# Build the native library
make -C libcalc/

# Publish with overlays (from the repo root)
qlot exec ros -e '
(asdf:load-system "cl-repository-packager")
(let* ((spec (make-instance (quote cl-repository-packager/build-matrix:package-spec)
               :name "cl-calc"
               :version "1.0.0"
               :source-dir #p"examples/07-multiplatform-native-ci/cl-calc/"
               :license "MIT"
               :depends-on (list "cffi")
               :provides (list "cl-calc")
               :cffi-libraries (list "libcalc")
               :overlays (list
                 (make-instance (quote cl-repository-packager/build-matrix:overlay-spec)
                   :os "linux" :arch "amd64"
                   :native-paths (list "examples/07-multiplatform-native-ci/libcalc/libcalc.so")))))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (cl-repository-packager/publisher:publish-package
    "http://localhost:5050" "cl-systems" "1.0.0" result spec))'

# Verify
oras manifest fetch localhost:5050/cl-systems/cl-calc:1.0.0 | jq .

# Install and use
qlot exec ros -e '
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "http://localhost:5050" :namespace "cl-systems")
(cl-repo:load-system "cl-calc")
(format t "calc_version: ~a~%" (cl-calc:calc-version))
(format t "2 + 3 = ~a~%" (cl-calc:calc-add 2 3))'

# Cleanup
docker stop oci-registry && docker rm oci-registry
```

## Using a Standard OCI Client

No cl-repo tooling required. Each overlay manifest is self-contained. All layers use the same OCICL-compatible `<name>-<version>/` prefix, so they overlay cleanly:

```sh
oras pull --platform linux/amd64 ghcr.io/cl-systems/cl-calc:1.0.0
for f in *.tar.gz; do tar xzf "$f"; done
# -> cl-calc-1.0.0/          (source)
# -> cl-calc-1.0.0/native/   (platform libs)
```

Without `--platform`, `oras` selects the first manifest (universal, source-only).

## Client Resolution

When a user runs `(cl-repo:load-system "cl-calc")`, the client:

1. Pulls the Image Index
2. Detects local OS/arch via `trivial-features` (e.g., `darwin/arm64`)
3. Always selects the universal manifest (source code)
4. Matches an overlay by `platform.os` + `platform.architecture`
5. Extracts source to `systems/cl-calc/1.0.0/`, overlay native lib to `systems/cl-calc/1.0.0/native/`
6. Generates `cl-repo-init.lisp` that pushes `native/` into `cffi:*foreign-library-directories*`
7. CFFI loads `libcalc` transparently -- no C compiler needed at install time
