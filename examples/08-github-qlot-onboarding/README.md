# GitHub + qlot Onboarding

Onboard projects into an OCI registry from either GitHub repos or `qlot` metadata.

## Prerequisites

- SBCL + Roswell + qlot
- `git` in PATH
- A writable OCI registry namespace

## Publish directly from GitHub

```bash
cl-repo publish-github fukamachi/sxql \
  --ref main \
  --registry ghcr.io \
  --namespace my-org/my-project
```

Notes:
- `publish-github` accepts `owner/repo` or full GitHub URL.
- `--system` is useful when a repo has multiple `.asd` files.
- The package is annotated with source and revision provenance.

## Sync from qlot file

Given a `qlfile` such as:

```text
ql alexandria
ql cl-ppcre
github fukamachi/sxql main
git https://github.com/edicl/cl-ppcre.git master
```

Install OCI-resolved dependencies only (auto-detect `qlfile` from current/parent dirs):

```bash
cl-repo sync-qlot \
  --registry ghcr.io \
  --namespace my-org/my-project
```

Install + publish source entries (`github`/`git`) during sync:

```bash
cl-repo sync-qlot --publish-sources \
  --registry ghcr.io \
  --namespace my-org/my-project
```

Use lockfile pins (auto-detect `qlfile.lock` from current/parent dirs):

```bash
cl-repo sync-qlot --use-lock --publish-sources \
  --registry ghcr.io \
  --namespace my-org/my-project
```

Override file locations only when needed:

```bash
cl-repo sync-qlot --use-lock \
  --qlfile /path/to/qlfile \
  --qlfile-lock /path/to/qlfile.lock \
  --registry ghcr.io \
  --namespace my-org/my-project
```

## Reproducible restore

After installation, write lockfile and restore with digest checks:

```bash
cl-repo lock
cl-repo restore --registry ghcr.io --namespace my-org/my-project
```
