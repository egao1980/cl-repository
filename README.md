# CL Repository

<img src="https://img.shields.io/badge/WARN-LLM%20GENERATED-FF6347"/>

OCI-based distribution system for Common Lisp packages.

Language versions:
- English: `README.md`
- Russian: `README.ru.md`
- Japanese: `README.ja.md`

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

```sh
cl-repo sync
cl-repo test
cl-repo publish
```

A stock `.asd` is enough. `qlfile` / `qlfile.lock` in the same directory are installed too.
The registry defaults to `https://ghcr.io` / `egao1980/cl-systems`. No `CL_SOURCE_REGISTRY`.

### CLI

```sh
cl-repo sync
cl-repo test
cl-repo run -- sbcl --script tool.lisp
cl-repo publish
cl-repo add-overlay
cl-repo publish --overlay
cl-repo install alexandria
```

### Onboarding Existing Projects

You can onboard projects that are not yet in your OCI registry without first adding them to a Quicklisp dist.

```sh
# qlfile and qlfile.lock are part of sync. A missing system is published, then installed.
cl-repo sync
```

### Embedded OCI Config in .asd

```lisp
(defsystem "my-lib"
  :version "1.0.0"
  :depends-on ("cffi")
  :properties (:cl-repo (:cffi-libraries ("libfoo")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :layers ((:role "native-library"
                                                :files (("lib/libfoo.so" . "libfoo.so"))))))))
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
cl-repo publish my-cffi-lib --registry ghcr.io --namespace my-org/my-project
```

2. **Build native libraries** on each target platform (in CI or locally).

3. **Record the overlay in the `.asd`**, then publish it. `add-overlay` only edits the file. A bare call is this machine's os and arch. Passing any of `--os`, `--arch`, `--lisp` keeps only those parts (a bare flag means this machine). Put the built files in `lib/<key>/` and grovel output in `grovel/<key>/`.

```sh
cl-repo add-overlay --os linux --arch amd64
cl-repo add-overlay --lisp ecl
cl-repo publish
cl-repo publish --overlay
```

`publish` pushes the source manifest and every overlay whose files exist. `publish --overlay` skips source and pushes the most specific match for this machine. `publish --overlay cuda` pushes that named overlay. `sync` installs every matching unnamed overlay, generic first. A name such as `cuda` stays out until `cl-repo sync --overlay cuda`.

#### Reusable workflow (native overlays)

For the parallel matrix → artifact → atomic publish pattern (grpc / cl-stack-ssl style), call:

`egao1980/cl-repository/.github/workflows/publish-native-package.yml@main`

See [docs/ci-native-publish.md](docs/ci-native-publish.md). Caller builds `native-<os>-<arch>` artifacts; the reusable job stages Lisp sources, packages overlays, and pushes to `ghcr.io/<owner>/cl-systems/<package>:<version>`.

#### Consumer CI (canned actions)

Do **not** copy `ci-install.lisp` / `ci-test.lisp` / `publish-checkout.lisp`. Packaging and CI extras live in the `.asd` (`:depends-on` + `:properties (:cl-repo …)`). Hooks in `scripts/ci/` only when the canned path is not enough.

```yaml
jobs:
  test:
    uses: egao1980/cl-repository/.github/workflows/test-system.yml@main
```

Ubuntu jobs in `test-system.yml` / `publish-source.yml` run in
`ghcr.io/egao1980/cl-repository/ci-base` (Roswell + SBCL + client already
installed). That is `jobs.<id>.container` — not a Docker container action.
macOS / Windows cannot use a job container; they install on the VM (cached).

Other implementations (ECL / CCL / ABCL) use `test-system-impl.yml` — same
install/test phases on the VM, impl installed and cached by Roswell. ECL
defaults to `26.5.5` (the cl-stack-mobile pin):

```yaml
jobs:
  test-ecl:
    uses: egao1980/cl-repository/.github/workflows/test-system-impl.yml@main
    with:
      lisp: ecl            # or ccl-bin / abcl-bin (JNA wired for CFFI)
```

Or compose:

```yaml
permissions:
  contents: read
  packages: read
# Ubuntu only — omit container: on macos/windows.
container: ghcr.io/egao1980/cl-repository/ci-base:latest
defaults:
  run: { shell: bash }
steps:
  - uses: actions/checkout@v5
  - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
  - uses: egao1980/cl-repository/.github/actions/ci@main
    with: { phase: install }
  - uses: egao1980/cl-repository/.github/actions/ci@main
    with: { phase: test }
```

Source-only publish: `egao1980/cl-repository/.github/workflows/publish-source.yml@main`. Natives: `publish-native-package.yml`. Details: [`.github/actions/ci`](.github/actions/ci/).

`setup-lisp` puts the client on the runner and does not export `CL_SOURCE_REGISTRY`. On a bare VM it runs `setup-client` + `setup-roswell`, caching `~/.roswell` and `.cl-repository` (client key = resolved semver, never the `:latest` alias). `setup-client` resolves `ghcr.io/egao1980/cl-repository/cl-repository-client:latest` (system-name **anchor**) → annotated semver → `oras pull`. **Do not pin a git tag of this repo for the Lisp client** — pass `version` only to freeze the OCI artifact. Call `setup-lisp` in **every job** that needs the client (runner disks are not shared). The job then runs `cl-repo sync` and `cl-repo test`.

#### CI Example (GitHub Actions)

```yaml
jobs:
  publish-source:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
      - run: cl-repo publish

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
      - uses: actions/checkout@v5
      - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
      - run: make native
      - run: cl-repo add-overlay --os ${{ matrix.os }} --arch ${{ matrix.arch }}
      - run: cl-repo publish --overlay
```

The client automatically selects the matching overlay at install time — pure-Lisp systems skip overlays entirely.

### Install

```sh
cl-repo install alexandria
cl-repo install cffi:0.24.1
```

The artifacts are ordinary OCI images. `oras`, `crane`, and `skopeo` can pull them. Installing into ASDF is `cl-repo install`.

### Loading OCICL Packages

`cl-repo` can pull packages from [OCICL](https://github.com/ocicl/ocicl) registries (`ghcr.io/ocicl/*`). Register the OCICL namespace with `:type :ocicl`:

```lisp
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
(cl-repo:load-system "alexandria")
```

Mix cl-repo and OCICL registries — the client searches in order:

```lisp
(cl-repo:add-registry "https://ghcr.io" :namespace "my-org/my-project")          ; cl-repo format (GitHub default)
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)          ; OCICL format
(cl-repo:load-system "alexandria")  ; tries cl-repo first, falls back to OCICL
```

OCICL differences handled automatically: empty config blobs, tarball prefix stripping, date-commit version tags.

cl-repo packages are also OCICL-compatible — the source layer uses an `<name>-<version>/` root directory prefix and a matching layer title (`<name>-<version>.tar.gz`), so OCICL's client can consume cl-repo packages directly.

### Protected Systems

When running inside a live Lisp image (e.g. connected via Swank/SLIME or Slynk/SLY), updating certain systems can break active connections. `cl-repository-client` provides two protection mechanisms that are enabled by default:

**1. Prefix-based protection** -- systems matching `*protected-system-prefixes*` (default: `("swank" "slynk")`) are skipped when the corresponding package is present in the image. This covers the main system and all subsystems (e.g. `swank/sbcl`, `slynk/mrepl`).

**2. Loaded-systems snapshot** -- on first use of `load-system` or `update`, a snapshot of all currently registered ASDF systems is taken. These systems are never updated or reinstalled. Controlled by `*protect-loaded-systems*` (default: `T`).

```lisp
;; Programmatic API
(setf cl-repo:*protected-system-prefixes* '("swank" "slynk" "my-server"))
(setf cl-repo:*protect-loaded-systems* t)     ; default
(cl-repo:snapshot-loaded-systems)              ; explicit snapshot (normally automatic)
```

CLI: use `--protect` (repeatable) to add extra prefixes:

```sh
cl-repo update --protect hunchentoot --protect my-app
cl-repo load alexandria --protect swank
```

Use `--force` to override all protection and force-update.

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
| [08-github-qlot-onboarding](examples/08-github-qlot-onboarding/) | Onboard GitHub and qlot projects into OCI |

## Development

Requires [Roswell](https://github.com/roswell/roswell) and [qlot](https://github.com/fukamachi/qlot).

```sh
qlot install
qlot exec ros run
```

Or use the devcontainer (VS Code / Cursor with Roswell + Alive features).

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

Local GitHub Actions testing with Docker + `act`:

```sh
act -W .github/workflows/test.yml -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

See full tutorial: [docs/tutorial-local-testing-docker-act.md](docs/tutorial-local-testing-docker-act.md).

## License

MIT
