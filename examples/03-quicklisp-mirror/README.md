# Quicklisp Mirror

Mirror Quicklisp libraries into a private OCI registry for offline/airgapped use or corporate environments.

## Prerequisites

- SBCL + Roswell + qlot
- Docker

## Start the registry

```bash
docker compose up -d
```

## Export specific libraries

```lisp
(asdf:load-system "cl-repository-ql-exporter")

(cl-repository-ql-exporter/exporter:export-dist
  "http://beta.quicklisp.org/dist/quicklisp.txt"
  "http://localhost:5050"
  :namespace "cl-systems"
  :filter "alexandria,cl-ppcre,split-sequence,babel,ironclad")
```

## Export everything (bulk)

```lisp
(cl-repository-ql-exporter/exporter:export-dist
  "http://beta.quicklisp.org/dist/quicklisp.txt"
  "http://localhost:5050"
  :namespace "cl-systems")
```

## Incremental sync

Re-run and skip already-pushed projects:

```lisp
(cl-repository-ql-exporter/exporter:export-dist
  "http://beta.quicklisp.org/dist/quicklisp.txt"
  "http://localhost:5050"
  :namespace "cl-systems"
  :incremental t)
```

## Dry-run

See what would be pushed without pushing:

```lisp
(cl-repository-ql-exporter/exporter:export-dist
  "http://beta.quicklisp.org/dist/quicklisp.txt"
  "http://localhost:5050"
  :namespace "cl-systems"
  :filter "alexandria,babel"
  :dry-run t)
```

## CLI

```bash
cl-repo ql-export http://beta.quicklisp.org/dist/quicklisp.txt \
  --registry http://localhost:5050 --namespace cl-systems

# Incremental
cl-repo ql-export http://beta.quicklisp.org/dist/quicklisp.txt \
  --registry http://localhost:5050 --incremental
```

## Use the mirror

```lisp
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "http://localhost:5050" :namespace "cl-systems")
(cl-repo:load-system "alexandria")
```

## Verify with external tools

```bash
# List all mirrored repos
curl -s http://localhost:5050/v2/_catalog | jq .

# List tags for a library
curl -s http://localhost:5050/v2/cl-systems/alexandria/tags/list | jq .

# Pull with oras
oras pull localhost:5050/cl-systems/alexandria:20241012-git -o /tmp/alexandria/
```

## Teardown

```bash
docker compose down -v
```
