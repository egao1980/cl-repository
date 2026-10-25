# GitHub + qlot Onboarding

Onboard projects into an OCI registry from either GitHub repos or `qlot` metadata.

## Prerequisites

- SBCL + Roswell + qlot
- `git` in PATH
- A writable OCI registry namespace

## Sync

A directory with an `.asd`, a `qlfile`, or both is a project. `qlfile.lock` wins when it is present.
Missing `ql`, `github`, `git`, and `http` entries are published, then installed. Defaults are
`https://ghcr.io` and `egao1980/cl-systems`.

```text
ql alexandria
github fukamachi/sxql main
```

```bash
cl-repo sync
cl-repo test
```

## Reproducible restore

After installation, write lockfile and restore with digest checks:

```bash
cl-repo lock
cl-repo restore --registry ghcr.io --namespace my-org/my-project
```
