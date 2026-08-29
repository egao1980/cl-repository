# ci-base

Prebuilt GitHub Actions **job container** with Roswell, SBCL, oras, and `cl-repository-client`.

This is `jobs.<job_id>.container`, not a Docker container action (`runs.using: docker`).
A Docker action starts an isolated sibling and only persists `/github/workspace` — it cannot
leave `ros` / SBCL on the runner for later `ci` steps.

Image: `ghcr.io/egao1980/cl-repository/ci-base:latest`

Linux / Ubuntu runners only. macOS and Windows still use `setup-roswell` + `setup-client`.

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    container: ghcr.io/egao1980/cl-repository/ci-base:latest
    defaults:
      run:
        shell: bash   # job-container default is sh
    steps:
      - uses: actions/checkout@v5
      - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
      - uses: egao1980/cl-repository/.github/actions/ci@main
        with: { phase: install }
      - uses: egao1980/cl-repository/.github/actions/ci@main
        with: { phase: test }
```

`test-system.yml` / `publish-source.yml` do this for Ubuntu automatically.

Rebuild: `.github/workflows/publish-ci-base.yml` (push to `main` touching this dir, Monday cron, or `workflow_dispatch`).
