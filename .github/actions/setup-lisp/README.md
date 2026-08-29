# setup-lisp

One entry point for consumer jobs:

1. **Job is in `ci-base`** (`/opt/cl-ci/ok`) — symlink `$HOME/.roswell` (GHA remaps `HOME` to `/github/home`) and export `CL_*`. No download.
2. **Otherwise** (macOS / Windows / Ubuntu without `container:`) — `setup-roswell` + `setup-client`, with `actions/cache` on `~/.roswell`.

Do **not** use a Docker container action (`runs.using: docker`) for this. That runs in an isolated sibling; only the workspace is shared, so SBCL would vanish before `ci`.

```yaml
# Ubuntu — reuse the baked image (test-system.yml does this).
jobs:
  test:
    runs-on: ubuntu-latest
    container: ghcr.io/egao1980/cl-repository/ci-base:latest
    defaults:
      run: { shell: bash }
    steps:
      - uses: actions/checkout@v5
      - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
      - uses: egao1980/cl-repository/.github/actions/ci@main
        with: { phase: install }

# macOS / Windows — no job container (docs: Linux runner required).
      - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
```

Prefer `test-system.yml` so the container wiring stays in one place.
