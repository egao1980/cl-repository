# Reusable GHA: publish native OCI packages

Workflow: [`.github/workflows/publish-native-package.yml`](../.github/workflows/publish-native-package.yml)

Formalizes the pattern used by `grpc` / `cl-protobufs` / `cl-stack-ssl`:

1. **Caller** builds natives on a matrix and uploads artifacts `native-<os>-<arch>`
2. **This workflow** arranges `lib/<os>-<arch>/`, stages a Lisp-only source tree, runs `cl-repository-packager`, publishes to `ghcr.io/<owner>/cl-systems/<package>:<version>`, verifies with `oras`

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
      - uses: actions/checkout@v4
      - name: Build natives
        run: ./scripts/build-natives.sh   # → lib/${{ matrix.os }}-${{ matrix.arch }}/
      - run: |
          mkdir -p native-bundle
          cp -a "lib/${{ matrix.os }}-${{ matrix.arch }}/." native-bundle/
      - uses: actions/upload-artifact@v4
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
      description: "…"
      depends-on: cffi
      cffi-libraries: libfoo
      source-paths: |
        my-lib.asd
        src
        LICENSE
        README.md
    secrets: inherit
```

## Inputs (summary)

| Input | Required | Notes |
|-------|----------|-------|
| `package-name` | yes | OCI repo + ASDF name |
| `version` | yes | tag |
| `source-paths` | yes | Lisp-only files/dirs (natives stay in artifacts) |
| `depends-on` / `cffi-libraries` / `provides` | no | space-separated |
| `namespace` | no | default `<owner>/cl-systems` |
| `packager-tag` | no | default `0.8.0` |
| `skip-catalog` | no | default `true` |
| `ci-ref` | no | cl-repository ref for `scripts/ci` (default `main`) |

## Helpers

| Script | Role |
|--------|------|
| `scripts/ci/arrange-native-artifacts.sh` | `native-*` → `lib/<os>-<arch>/` + platforms.txt |
| `scripts/ci/stage-lisp-source.sh` | copy `source-paths` into staging |
| `scripts/ci/publish-native-package.lisp` | build-package + publish-package |

## Contract

- Artifact names **must** be `native-<os>-<arch>`
- Overlay file lists use **absolute** paths from arranged `lib/` (via `uiop:directory-files`) so the source tarball stays Lisp-only
- Publish uses `:skip-catalog t` by default (cross-repo catalog 403)
