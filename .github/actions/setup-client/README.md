# setup-client

Composite action: `oras` pull **`cl-repository-client`** from GHCR and export it to later steps.

**Do not pin a git tag of this repo for the Lisp client.** The action default is OCI `:latest` (system-name anchor → annotated semver → `oras pull …:<semver>`). Pin `version` only to freeze a known-bad day.

```yaml
permissions:
  contents: read
  packages: read

steps:
  - uses: actions/checkout@v5
  - uses: egao1980/cl-repository/.github/actions/setup-client@main
  - uses: egao1980/cl-repository/.github/actions/setup-roswell@main
    with:
      sbcl-version: ${{ env.SBCL_VERSION }}
      roswell-version: ${{ env.ROSWELL_VERSION }}
  # CL_SOURCE_REGISTRY / CL_REPOSITORY_CLIENT_DIR already on GITHUB_ENV
  - run: ros -l scripts/ci-install.lisp -q
  - run: ros -l scripts/ci-test.lisp -q
```

Use `@main` for the **action YAML**. The **artifact** still tracks GHCR `latest` unless you pass `version`.

## Other jobs

GitHub does not share the runner disk across jobs. Call this action **in every job** that needs the client (same as `actions/setup-node`). Outputs exist so a setup job can forward the resolved version:

```yaml
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    permissions:
      contents: read
      packages: read
    steps:
      - uses: actions/checkout@v5
      - uses: egao1980/cl-repository/.github/actions/setup-client@main
      - run: ros -l scripts/ci-install.lisp -q
```

## Inputs / env

| Input | Default | Meaning |
|-------|---------|---------|
| `version` | `latest` | OCI tag; `latest` is the name-anchor |
| `image` | `ghcr.io/egao1980/cl-repository/cl-repository-client` | |
| `systems` | `ghcr.io/egao1980/cl-systems` | Namespace for qlfile bootstrap deps |
| `pull-deps` | `true` | oras-pull qlfile systems + transitive `depends-on` from cl-systems (no QL) |
| `dest` | `.cl-repository` | Extract root |
| `oras-version` | `1.2.3` | |

Roswell is not required for this action. Client Lisp deps come from `ghcr.io/egao1980/cl-systems` (`:latest` anchor if present, otherwise highest version tag). ASDF names with `+` map to GHCR `-plus-` (`cl+ssl` → `cl-plus-ssl`). Missing packages fail the step.

## Outputs / env

`client-dir`, `client-version`, `dest`, `source-registry` — also `GITHUB_ENV`:

- `CL_SOURCE_REGISTRY` — `${workspace}//:${dest}//:`
- `CL_REPOSITORY_CLIENT_DIR`
- `CL_REPOSITORY_CLIENT_VERSION` — resolved semver, not `latest`
