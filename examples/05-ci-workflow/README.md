# CI/CD Workflow

Publish Common Lisp packages from GitHub Actions and consume them with `cl-repo`.

## Overview

```
push to main ──> GitHub Actions ──> build OCI artifact ──> push to GHCR
                                                              │
                                    cl-repo:load-system ◄─────┘
```

## GitHub Actions: Publish on tag

`.github/workflows/publish.yml` builds and pushes the system to GHCR when a version tag is pushed.

Key steps:
1. Set up SBCL via Roswell
2. Load the packager
3. Build the OCI artifact
4. Push to `ghcr.io/<owner>/<repo>/<name>:<version>`

## GitHub Actions: Test with cl-repo

`.github/workflows/test.yml` installs dependencies from an OCI registry before running tests.

## Consuming published packages

```lisp
(asdf:load-system "cl-repository-client")

;; Use GHCR as a registry (public packages, no auth needed)
(cl-repo:add-registry "https://ghcr.io" :namespace "my-org/my-project")

(cl-repo:load-system "my-library")
```

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
