# Publish a System

Build a Common Lisp system into an OCI artifact and push it to a registry.

## Prerequisites

- SBCL + Roswell + qlot
- A running OCI registry

## Start the registry

```bash
docker compose up -d
```

## The example system

`my-math/` contains a minimal ASDF system:

```
my-math/
  my-math.asd
  package.lisp
  math.lisp
```

## Publish from REPL

```lisp
(asdf:load-system "cl-repository-packager")

;; 1. Build the OCI artifact
(let ((spec (make-instance 'cl-repository-packager/build-matrix:package-spec
              :name "my-math"
              :version "1.0.0"
              :source-dir #p"my-math/"
              :description "A tiny math library"
              :author "Me"
              :depends-on nil
              :provides '("my-math"))))
  (defvar *result* (cl-repository-packager/build-matrix:build-package spec)))

;; 2. Push to registry
(cl-repository-packager/publisher:publish-package
  "http://localhost:5050" "cl-systems/my-math" "1.0.0" *result*)
```

## Publish via ASDF plugin

If the system is already loadable by ASDF:

```lisp
(asdf:load-system "cl-repository-packager")

(let* ((spec (cl-repository-packager/asdf-plugin:auto-package-spec "my-math"))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (cl-repository-packager/publisher:publish-package
    "http://localhost:5050" "cl-systems/my-math" "1.0.0" result))
```

## Publish via CLI

```bash
cd my-math/
cl-repo publish --registry http://localhost:5050
```

## Verify with oras

```bash
oras manifest fetch localhost:5050/cl-systems/my-math:1.0.0 | jq .
```

## Load from another session

```lisp
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "http://localhost:5050")
(cl-repo:load-system "my-math")
(my-math:add 2 3)  ; => 5
```

## Teardown

```bash
docker compose down -v
```
