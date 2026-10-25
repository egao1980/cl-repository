# CI/CD Workflow

Publish Common Lisp packages from GitHub Actions and consume them with `cl-repo`.

## Overview

```
push to main ──> GitHub Actions ──> build OCI artifact ──> push to GHCR
                                                              │
                                    cl-repo:load-system ◄─────┘
```

## GitHub Actions: Publish

`.github/workflows/publish.yml` calls the reusable `publish-source.yml` (`.asd` + `auto-package-spec`). No per-repo `publish-checkout.lisp`.

## GitHub Actions: Test with cl-repo

Do **not** copy `scripts/ci-install.lisp`. Call the reusable workflow (reads `.asd`):

```yaml
jobs:
  test:
    uses: egao1980/cl-repository/.github/workflows/test-system.yml@main
```

CI extras that are not in `:depends-on` go in `:properties (:cl-repo (:ci (:with … :sources …)))`. Hooks: `scripts/ci/pre-test.lisp` etc. See `.github/actions/ci/README.md`.

## Consuming published packages

```sh
cl-repo install my-library
```

A namespace other than `egao1980/cl-systems` is `--namespace my-org/my-project`.

## Authentication

For private GHCR packages, set credentials before use:

```lisp
;; The OCI client reads standard OCI auth when available.
;; For GHCR, use a personal access token:
(cl-oci-client/registry:make-registry "https://ghcr.io"
  :auth (cl-oci-client/auth:make-auth-config
          :username "USERNAME"
          :password "ghp_TOKEN"))
```

Or via `docker login` / `oras login` which stores credentials in `~/.docker/config.json`.
