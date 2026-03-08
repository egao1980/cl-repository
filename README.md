# CL Repository

<img src="https://img.shields.io/badge/WARN-LLM%20GENERATED-FF6347"/>

OCI-based distribution system for Common Lisp packages.

Packages are standard OCI artifacts pushable to any OCI-compliant registry (GHCR, Docker Hub, Quay, etc.) and pullable by any OCI client (oras, crane, skopeo) or the included CL-native client.

## Why CL Repository?

Quicklisp is a great way to get started with Common Lisp libraries, but it has limitations. It provides a single curated snapshot that updates monthly -- there's no way to pin `cffi` at 0.24.1 while a colleague uses 0.25, and no lockfile for reproducible builds. More importantly, there's no built-in story for native dependencies. If a library wraps a C library via CFFI, every user needs the right headers and a compiler toolchain to run the groveler locally. On a fresh CI machine, that setup cost adds up quickly.

cl-repo takes a different approach: every CL system is packaged as an OCI artifact -- the same format used by Docker images. You push it to any container registry (GHCR, Docker Hub, your organization's Harbor instance) and pull it back with exact version tags. The registry you already use for container images works as your Lisp package registry too. No additional servers, no new accounts, no custom protocol.

The biggest practical benefit is **platform overlays**. Each package can include prebuilt `.so`/`.dylib`/`.dll` files and pre-groveled CFFI output for specific OS/arch combinations (linux/amd64, darwin/arm64, etc.). These are built once in CI and distributed alongside the source. When someone runs `cl-repo install cffi` on an M1 Mac, the client automatically selects the matching overlay -- no C compiler required at install time. Since CFFI grovel output depends on OS and architecture but not on the CL implementation, a single linux/amd64 overlay serves SBCL, CCL, and ECL equally well. Pure-Lisp systems skip overlays entirely and work everywhere with just a universal source manifest.

If you're familiar with qlot, cl-repo shares the same per-project dependency philosophy but replaces the transport layer. Where qlot pulls from Quicklisp and Ultralisp distributions, cl-repo pulls directly from OCI registries. It's also fully compatible with [OCICL](https://github.com/ocicl/ocicl) -- cl-repo packages work with the OCICL client and vice versa. And since these are standard OCI artifacts, you can always pull them with `oras`, `crane`, or `skopeo` without any Lisp tooling at all.

**At a glance:**

- Store packages in any OCI registry you already have (GHCR, Docker Hub, ECR, Harbor, self-hosted)
- Pin exact versions per project, with lockfile and digest pinning for reproducible CI builds
- Platform overlays: ship prebuilt native libs + pre-groveled CFFI per OS/arch -- no C compiler at install time
- Grovel once, use everywhere: one overlay per platform serves all CL implementations
- Standard OCI tooling: pull with `oras`, `crane`, `skopeo` -- no Lisp required
- Cross-compatible with OCICL

## Systems

| System | Description |
|--------|-------------|
| `cl-oci` | CLOS library modeling OCI Image and Distribution specifications |
| `cl-oci-client` | OCI Distribution Spec v1.1 HTTP client |
| `cl-repository-packager` | ASDF plugin + build matrix for packaging CL systems as OCI artifacts |
| `cl-repository-client` | Client library + CLI for installing packages from OCI registries |
| `cl-repository-ql-exporter` | Quicklisp/Ultralisp to OCI artifact bulk exporter |

## Quick Start

```lisp
;; Load a system from configured OCI registries (like ql:quickload)
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "cl-systems")
(cl-repo:load-system "alexandria")

;; Package and publish a system (reads OCI config from .asd :properties)
(asdf:load-system "cl-repository-packager")
(asdf:operate 'cl-repository-packager:package-op "my-system")
```

### CLI

```sh
cl-repo install alexandria
cl-repo install cffi:0.24.1
cl-repo publish
cl-repo ql-export https://beta.quicklisp.org/dist/quicklisp.txt --registry ghcr.io --namespace cl-systems
```

### Embedded OCI Config in .asd

```lisp
(defsystem "my-lib"
  :version "1.0.0"
  :depends-on ("cffi")
  :properties (:cl-repo (:cffi-libraries ("libfoo")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :native-paths ("lib/libfoo.so")))))
  :components (...))
```

See [docs/spec.md](docs/spec.md) for the full specification.

### Incremental Platform Overlays

Platform overlays are additive. You can publish a pure-Lisp package first, then add platform-specific overlays later (e.g., from CI jobs on different OS/arch runners).

#### Workflow

1. **Publish the source-only package** (universal manifest, no overlays):

```lisp
(defsystem "my-cffi-lib"
  :version "1.0.0"
  :depends-on ("cffi")
  :components (...))
```

```sh
cl-repo publish my-cffi-lib --registry ghcr.io --namespace cl-systems
```

2. **Build native libraries** on each target platform (in CI or locally).

3. **Add overlays** to the already-published package:

```sh
# On a linux/amd64 runner:
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 \
  --native-paths lib/linux-amd64/libfoo.so \
  --tag 1.0.0 \
  --registry ghcr.io --namespace cl-systems

# On a darwin/arm64 runner:
cl-repo add-overlay my-cffi-lib \
  --os darwin --arch arm64 \
  --native-paths lib/darwin-arm64/libfoo.dylib \
  --tag 1.0.0 \
  --registry ghcr.io --namespace cl-systems

# On a windows/amd64 runner:
cl-repo add-overlay my-cffi-lib \
  --os windows --arch amd64 \
  --native-paths lib/windows-amd64/foo.dll \
  --tag 1.0.0 \
  --registry ghcr.io --namespace cl-systems
```

Each `add-overlay` call pulls the existing Image Index, pushes the new overlay blobs and manifest, appends the overlay descriptor, and re-pushes the updated index under the same tag. OCI tags are mutable pointers, so this is safe and idempotent for distinct platform targets.

Multiple native files can be included in a single overlay (comma-separated):

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 \
  --native-paths lib/libfoo.so,lib/libbar.so \
  --tag 1.0.0
```

For ABI-sensitive overlays (grovel output, native libs linked against specific glibc/SDK), pin the OS version with `--os-version`. The client prefers exact os-version matches and falls back to generic os/arch overlays:

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 --os-version ubuntu-22.04 \
  --native-paths lib/linux-amd64-u2204/libfoo.so \
  --tag 1.0.0
```

If the overlay targets a specific CL implementation, pass `--lisp`:

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 --lisp sbcl \
  --native-paths lib/linux-amd64/libfoo.so \
  --tag 1.0.0
```

#### Programmatic API

```lisp
(let* ((overlay (parse-overlay-spec
                  '(:platform (:os "linux" :arch "amd64")
                    :native-paths ("lib/libfoo.so"))))
       (result (build-overlay "my-cffi-lib" overlay :version "1.0.0")))
  (publish-overlay "https://ghcr.io" "cl-systems" "my-cffi-lib" "1.0.0" result))
```

#### CI Example (GitHub Actions)

```yaml
jobs:
  publish-source:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cl-repo publish my-cffi-lib --registry ghcr.io --namespace cl-systems

  add-overlay:
    needs: publish-source
    strategy:
      matrix:
        include:
          - os: linux
            arch: amd64
            runner: ubuntu-latest
            lib: lib/linux-amd64/libfoo.so
          - os: darwin
            arch: arm64
            runner: macos-14
            lib: lib/darwin-arm64/libfoo.dylib
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - run: make native  # build the .so/.dylib
      - run: |
          cl-repo add-overlay my-cffi-lib \
            --os ${{ matrix.os }} --arch ${{ matrix.arch }} \
            --native-paths ${{ matrix.lib }} \
            --tag 1.0.0 \
            --registry ghcr.io --namespace cl-systems
```

The client automatically selects the matching overlay at install time — pure-Lisp systems skip overlays entirely.

### Using a Standard OCI Client (no cl-repo needed)

Packages are standard OCI artifacts — pull with any OCI client, then point ASDF at the extracted directory.

```sh
# Pull the source layer (downloads cl-oci-0.2.0.tar.gz)
oras pull ghcr.io/egao1980/cl-systems/cl-oci:0.2.0 -o /tmp/
# Extract — tarball has a root directory cl-oci-0.2.0/ (OCICL-compatible)
mkdir -p ~/.local/share/cl-systems/
tar -xzf /tmp/cl-oci-0.2.0.tar.gz -C ~/.local/share/cl-systems/
# Resulting directory: ~/.local/share/cl-systems/cl-oci-0.2.0/
```

Then in your Lisp:

```lisp
(asdf:initialize-source-registry
  '(:source-registry
    (:tree (:home ".local/share/cl-systems/"))
    :inherit-configuration))

(asdf:load-system "cl-oci")
```

Or set the `CL_SOURCE_REGISTRY` environment variable instead:

```sh
export CL_SOURCE_REGISTRY="(:source-registry (:tree (:home \".local/share/cl-systems/\")) :inherit-configuration)"
sbcl --eval '(asdf:load-system "cl-oci")'
```

For scripting, pull + extract + load in one shot:

```sh
#!/bin/sh
REGISTRY=ghcr.io/egao1980/cl-systems
SYSTEM=cl-oci
TAG=0.2.0
DEST=~/.local/share/cl-systems

mkdir -p "${DEST}"
oras pull "${REGISTRY}/${SYSTEM}:${TAG}" -o /tmp/
tar -xzf "/tmp/${SYSTEM}-${TAG}.tar.gz" -C "${DEST}/"

sbcl --eval "(asdf:initialize-source-registry
               '(:source-registry
                 (:tree (:home \".local/share/cl-systems/\"))
                 :inherit-configuration))" \
     --eval "(asdf:load-system \"${SYSTEM}\")" \
     --eval "(format t \"~a loaded OK~%\" \"${SYSTEM}\")"
```

This works with any OCI client (`oras`, `crane`, `skopeo`) and any CL implementation with ASDF.

### Loading OCICL Packages

`cl-repo` can pull packages from [OCICL](https://github.com/ocicl/ocicl) registries (`ghcr.io/ocicl/*`). Register the OCICL namespace with `:type :ocicl`:

```lisp
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
(cl-repo:load-system "alexandria")
```

Mix cl-repo and OCICL registries — the client searches in order:

```lisp
(cl-repo:add-registry "https://ghcr.io" :namespace "egao1980/cl-systems")         ; cl-repo format (default)
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)          ; OCICL format
(cl-repo:load-system "alexandria")  ; tries cl-repo first, falls back to OCICL
```

OCICL differences handled automatically: empty config blobs, tarball prefix stripping, date-commit version tags.

cl-repo packages are also OCICL-compatible — the source layer uses an `<name>-<version>/` root directory prefix and a matching layer title (`<name>-<version>.tar.gz`), so OCICL's client can consume cl-repo packages directly.

## Examples

| Example | Description |
|---------|-------------|
| [01-basic-usage](examples/01-basic-usage/) | Load systems from REPL and CLI |
| [02-publish-system](examples/02-publish-system/) | Build and publish a CL system |
| [03-quicklisp-mirror](examples/03-quicklisp-mirror/) | Mirror Quicklisp to OCI |
| [04-native-deps](examples/04-native-deps/) | CFFI + platform overlays |
| [05-ci-workflow](examples/05-ci-workflow/) | GitHub Actions CI/CD |
| [06-asd-embedded-config](examples/06-asd-embedded-config/) | OCI config embedded in .asd |
| [07-multiplatform-native-ci](examples/07-multiplatform-native-ci/) | Real C lib + CFFI grovel + multiplatform CI |

## Development

Requires [Roswell](https://github.com/roswell/roswell) and [qlot](https://github.com/fukamachi/qlot).

```sh
qlot install
qlot exec ros run
```

Or use the devcontainer (VS Code / Cursor with `egao1980/features` + `alive`).

### Running Tests

Unit tests:

```sh
qlot exec ros -e '(asdf:test-system "cl-oci")'
qlot exec ros -e '(asdf:test-system "cl-oci-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-packager")'
qlot exec ros -e '(asdf:test-system "cl-repository-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-ql-exporter")'
```

Integration tests (requires Docker OCI registry at `localhost:5050`):

```sh
docker run -d -p 5050:5000 --name oci-registry registry:2
qlot exec ros -e '(asdf:test-system "cl-repository-integration-tests")'
```

## License

MIT
