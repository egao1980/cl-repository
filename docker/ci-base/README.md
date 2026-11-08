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

## Tags

- `latest`: the newest build.
- `sbcl-<version>`: the newest build with that SBCL (`sbcl-2.6.7`).
- `client-<version>`: the image with that cl-repository-client baked in (`client-0.26.0`). Pin this when a job must not move.

`/opt/cl-ci/image.env` inside the image records what was baked (`CL_REPOSITORY_CLIENT_VERSION`,
`CL_CI_SBCL_VERSION`, …).

## When it's rebuilt

`.github/workflows/publish-ci-base.yml` runs:

- **after every client release.** A successful "Publish to GHCR" run for tag `vX.Y.Z` bakes
  exactly `X.Y.Z` and fails if the image holds anything else. Before this, the image kept an
  old client for weeks (0.23.2 through 0.24–0.26) and Ubuntu jobs ran it.
- on a push to `main` touching `docker/ci-base/`, `setup-client.sh` or the workflow;
- on the Monday cron (`latest` client, fresh `ubuntu:24.04` packages);
- on `workflow_dispatch`, with an optional `client-version` input (empty means `latest`).

Pull requests build and smoke-test the image without pushing.

## Building it locally

From the repository root (the Dockerfile copies `setup-client.sh` from `.github/`):

```sh
docker build -f docker/ci-base/Dockerfile \
  --build-arg CLIENT_VERSION=0.26.0 \
  --build-arg SBCL_VERSION=2.6.7 \
  -t ci-base:local .

docker run --rm ci-base:local bash -lc '. /opt/cl-ci/image.env; ros version; echo "client $CL_REPOSITORY_CLIENT_VERSION"'
```

`ROSWELL_VERSION` and `ORAS_VERSION` are build args too; the workflow's `env:` holds the pinned
values. Changing SBCL or Roswell is a one-line edit there, and the push to `main` rebuilds.
