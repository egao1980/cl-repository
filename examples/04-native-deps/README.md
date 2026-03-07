# Native Dependencies

Distribute a Common Lisp system with platform-specific native library overlays.

This example shows how to package a CFFI-based system that wraps a C library (`libfoo`) with separate overlays for Linux (x86_64, aarch64) and macOS (aarch64).

## Concept

The OCI Image Index acts as a multi-platform manifest:

```
Image Index
  ├── Manifest (universal)     → source code layer
  ├── Manifest (linux/amd64)   → libfoo.so for x86_64
  ├── Manifest (linux/arm64)   → libfoo.so for aarch64
  └── Manifest (darwin/arm64)  → libfoo.dylib for Apple Silicon
```

The client resolves the current platform, pulls the universal manifest plus the matching overlay, and extracts both to the install directory:

```
~/.local/share/cl-repository/systems/cffi-example/1.0.0/
  cffi-example.asd
  package.lisp
  bindings.lisp
  native/
    libfoo.so          ← or libfoo.dylib depending on platform
  cl-repo-init.lisp    ← auto-generated CFFI path setup
```

## Project structure

```
cffi-example/
  cffi-example.asd       # ASDF system with CFFI dep
  package.lisp
  bindings.lisp           # CFFI bindings to libfoo
overlays/
  linux-amd64/libfoo.so
  linux-arm64/libfoo.so
  darwin-arm64/libfoo.dylib
```

## Build the multi-platform package

```lisp
(asdf:load-system "cl-repository-packager")

(let* ((spec (make-instance 'cl-repository-packager/build-matrix:package-spec
               :name "cffi-example"
               :version "1.0.0"
               :source-dir #p"cffi-example/"
               :description "CFFI wrapper with native overlays"
               :depends-on '("cffi")
               :provides '("cffi-example")
               :cffi-libraries '("libfoo")
               :overlays (list
                 (make-instance 'cl-repository-packager/build-matrix:overlay-spec
                   :os "linux" :arch "amd64"
                   :files '(("overlays/linux-amd64/libfoo.so" . "libfoo.so"))
                   :role "native-library")
                 (make-instance 'cl-repository-packager/build-matrix:overlay-spec
                   :os "linux" :arch "arm64"
                   :files '(("overlays/linux-arm64/libfoo.so" . "libfoo.so"))
                   :role "native-library")
                 (make-instance 'cl-repository-packager/build-matrix:overlay-spec
                   :os "darwin" :arch "arm64"
                   :files '(("overlays/darwin-arm64/libfoo.dylib" . "libfoo.dylib"))
                   :role "native-library"))))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  ;; Push to registry
  (cl-repository-packager/publisher:publish-package
    "http://localhost:5050" "cl-systems/cffi-example" "1.0.0" result))
```

## Install on the client side

```lisp
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "http://localhost:5050")

;; The client auto-detects the platform, pulls the right overlay
(cl-repo:load-system "cffi-example")
```

The installer:
1. Pulls the universal manifest (source code)
2. Detects the current OS/arch
3. Pulls the matching overlay manifest
4. Extracts native libs to `native/` subdirectory
5. Generates `cl-repo-init.lisp` that adds `native/` to `cffi:*foreign-library-directories*`

## OCI annotations

The resulting OCI artifact includes:

```json
{
  "dev.common-lisp.system.has-native-deps": "true",
  "dev.common-lisp.system.cffi-libraries": "libfoo"
}
```

## Inspect with oras

```bash
oras manifest fetch localhost:5050/cl-systems/cffi-example:1.0.0 | jq .
```

## Teardown

```bash
docker compose down -v
```
