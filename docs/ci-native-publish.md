# Reusable GHA: publish native OCI packages

Workflow: [`.github/workflows/publish-native-package.yml`](../.github/workflows/publish-native-package.yml)

Formalizes the pattern used by `cl-stack-brotli` / `cl-stack-zstd` / `event-backend-*` / `cl-stack-ssl`:

1. **Caller** builds natives on a matrix and uploads artifacts `native-<os>-<arch>`
2. **This workflow** arranges `lib/<os>-<arch>/`, stages a Lisp-only source tree, loads packager/oci-client via `setup-lisp` + `cl-repo:ensure-systems` (same as `publish-source.yml`), runs `auto-package-spec` from the `.asd` + artifact overlays, publishes to `ghcr.io/<owner>/cl-systems/<package>:<version>`, verifies with `oras`

Native binaries stay in artifact overlays. Lisp (packager, client, publish script) is ordinary `ros -l` after `setup-lisp`. Do **not** apt-install SBCL, bootstrap Quicklisp, or `oras pull` the packager tarball.

Packaging truth is the **`.asd`** (`:version` / `:depends-on` / `:properties (:cl-repo …)`). YAML `depends-on` / `cffi-libraries` / `provides` are optional overrides only.

## Caller skeleton

```yaml
name: Publish OCI Package
on:
  push:
    tags: ["v*"]
  workflow_dispatch:
    inputs:
      version:
        required: false
        default: ""

jobs:
  build:
    strategy:
      fail-fast: true
      matrix:
        include:
          - os: linux
            arch: amd64
            runner: ubuntu-latest
          - os: linux
            arch: arm64
            runner: ubuntu-24.04-arm64
          - os: darwin
            arch: arm64
            runner: macos-latest
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v5
      - name: Build natives
        run: ./scripts/build-natives.sh   # → lib/${{ matrix.os }}-${{ matrix.arch }}/
      - run: |
          mkdir -p native-bundle
          cp -a "lib/${{ matrix.os }}-${{ matrix.arch }}/." native-bundle/
      - uses: actions/upload-artifact@v6
        with:
          name: native-${{ matrix.os }}-${{ matrix.arch }}
          path: native-bundle/

  publish:
    needs: build
    permissions:
      contents: read
      packages: write
    uses: egao1980/cl-repository/.github/workflows/publish-native-package.yml@main
    with:
      package-name: my-lib
      version: ${{ inputs.version || github.ref_name }}  # strip v* in a prior step if needed
      packager-tag: "latest"
      source-paths: |
        my-lib.asd
        src
        LICENSE
        README.md
    secrets: inherit
```

Declare `:cffi-libraries` / `:overlays` / `:provides` under `:properties (:cl-repo …)` in `my-lib.asd`. Overlay relative paths in the `.asd` are inventory for docs/consumers; CI replaces them with absolute artifact paths at publish time.

## Inputs (summary)

| Input | Required | Notes |
|-------|----------|-------|
| `package-name` | yes | OCI repo + ASDF name |
| `version` | yes | tag (overrides `.asd` `:version` when set) |
| `source-paths` | yes | Lisp-only files/dirs (natives stay in artifacts) |
| `depends-on` / `cffi-libraries` / `provides` / `description` / `license` | no | optional overrides; prefer `.asd` |
| `namespace` | no | default `<owner>/cl-systems` |
| `packager-tag` | no | default `latest` — `cl-repo:ensure-systems` (not raw oras) |
| `source-overlay-artifact` | no | unpack over workspace after checkout (e.g. version-synced `.asd`) |
| `skip-catalog` | no | default `true` |
| `ci-ref` | no | override `scripts/ci` git ref (empty → this workflow's SHA) |
| `client-version` / `sbcl-version` / `roswell-version` / `ci-image` | no | same defaults as `publish-source.yml` |
| `sbcl-dynamic-space-mb` | no | `ros dynamic-space-size=` for overlay gzip (default `8192`). CUDA-sized `.so`s OOM the default ~1GB heap. |

## Helpers

| Script | Role |
|--------|------|
| `scripts/ci/arrange-native-artifacts.sh` | `native-*` → `lib/<os>-<arch>/` (+ `grovel/` if nested) + platforms.txt |
| `scripts/ci/stage-lisp-source.sh` | copy `source-paths` into staging |
| `scripts/ci/ensure-packager.lisp` | `cl-repo:ensure-systems` of packager + oci-client (no QL) |
| `scripts/ci/publish-native-package.lisp` | entry: load ensure + impl |
| `scripts/ci/publish-native-package-impl.lisp` | `auto-package-spec` + artifact overlays → publish (`cffi-grovel-output` when `grovel/` present) |

## Contract

- Artifact names **must** be `native-<os>-<arch>`
- Overlay file lists use **absolute** paths from arranged `lib/` (via `uiop:directory-files`) so the source tarball stays Lisp-only
- Publish uses `:skip-catalog t` by default (cross-repo catalog 403). That skips only the shared `<namespace>/catalog` repo. System-name `:latest` anchors on the package repo are still written.

### Artifact layouts

| Layout | Contents of `native-<os>-<arch>/` | Arranged as |
|--------|-----------------------------------|-------------|
| Flat | `libfoo.so` … | `lib/<os>-<arch>/` → role `native-library` |
| Nested | `lib/` + `grovel/` | `lib/<os>-<arch>/` → `native-library`; `grovel/<os>-<arch>/` → `cffi-grovel-output` |

Nested is required for packages that ship pre-groveled CFFI (event backends). Flat remains the OpenSSL / pure-native path.
