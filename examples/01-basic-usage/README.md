# Basic Usage

Load Common Lisp systems from an OCI registry with `cl-repo:load-system`.

## Prerequisites

- SBCL + Roswell + qlot
- A running OCI registry (this example uses a local one)

## Start the registry

```bash
docker compose up -d
```

## Load and use from REPL

```lisp
;; Load the client
(asdf:load-system "cl-repository-client")

;; Point at your registry
(cl-repo:add-registry "http://localhost:5050" :namespace "cl-systems")

;; Load a single system (installs from OCI if not cached)
(cl-repo:load-system "alexandria")

;; Load multiple systems
(cl-repo:load-system '("split-sequence" "cl-ppcre"))

;; Pin a version
(cl-repo:load-system "alexandria" :version "20241012-git")

;; Silent mode
(cl-repo:load-system "alexandria" :silent t)
```

## Multiple registries

Registries are searched in order. First match wins.

```lisp
(cl-repo:add-registry "http://localhost:5050" :namespace "cl-systems")
(cl-repo:add-registry "https://ghcr.io" :namespace "cl-systems")

;; Searches localhost first, then ghcr.io
(cl-repo:load-system "my-private-lib")
```

## Dry-run / quiet

```lisp
;; See what would happen without doing it
(let ((cl-oci:*dry-run* t))
  (cl-repo:load-system "alexandria"))

;; Suppress all output
(let ((cl-oci:*quiet* t))
  (cl-repo:load-system "alexandria"))
```

## CLI equivalent

```bash
cl-repo load alexandria --registry http://localhost:5050
cl-repo load alexandria split-sequence cl-ppcre --registry http://localhost:5050
cl-repo list
```

## Teardown

```bash
docker compose down -v
```
