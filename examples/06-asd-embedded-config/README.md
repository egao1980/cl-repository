# OCI Config Embedded in .asd

Embed all OCI packaging metadata directly in your `.asd` file using ASDF's `:properties`. No separate build scripts needed -- `auto-package-spec` reads the config and builds the right OCI artifact.

## How it works

ASDF supports a `:properties` plist on system definitions. We use the `:cl-repo` key to store OCI packaging metadata:

```lisp
(defsystem "my-lib"
  :version "2.0.0"
  :description "Example with embedded OCI config"
  :author "Me"
  :license "MIT"
  :depends-on ("alexandria" "cffi")
  :properties (:cl-repo (:cffi-libraries ("libcrypto")
                          :provides ("my-lib" "my-lib/utils")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :native-paths ("lib/linux-amd64/libcrypto.so"))
                                     (:platform (:os "darwin" :arch "arm64")
                                      :native-paths ("lib/darwin-arm64/libcrypto.dylib")))))
  :serial t
  :components ((:file "package")
               (:file "utils")
               (:file "main")))
```

## Supported `:cl-repo` keys

| Key | Type | Description |
|-----|------|-------------|
| `:cffi-libraries` | list of strings | CFFI foreign library names |
| `:provides` | list of strings | System names this package provides (default: system name) |
| `:overlays` | list of plists | Platform-specific overlay specs |

### Overlay plist format

```lisp
(:platform (:os "linux" :arch "amd64" :lisp "sbcl")  ; :lisp is optional
 :native-paths ("path/to/lib.so" ...)
 :run-groveler t                                       ; optional
 :cffi-wrapper-systems ("my-wrapper-system"))           ; optional
```

## Build and publish

```lisp
(asdf:load-system "cl-repository-packager")

;; auto-package-spec reads everything from the .asd
(let* ((spec (cl-repository-packager/asdf-plugin:auto-package-spec "my-lib"))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (cl-repository-packager/publisher:publish-package
    "http://localhost:5050" "cl-systems/my-lib" "2.0.0" result))
```

Or via CLI:

```bash
cd my-lib/
cl-repo publish --registry http://localhost:5050
```

`auto-package-spec` introspects the loaded ASDF system and merges:
- Standard ASDF fields: `:version`, `:description`, `:author`, `:license`, `:depends-on`
- OCI-specific fields from `:properties :cl-repo`

## Example systems

### Simple (source only)

See `string-tools/string-tools.asd` -- no native deps, just source.

### With native overlays

See `crypto-wrapper/crypto-wrapper.asd` -- CFFI bindings with per-platform overlays.

## Start the registry

```bash
docker compose up -d
```

## Run the demo

```lisp
;; Publish string-tools (source only)
(asdf:load-system "cl-repository-packager")
(let* ((spec (cl-repository-packager/asdf-plugin:auto-package-spec "string-tools"))
       (result (cl-repository-packager/build-matrix:build-package spec)))
  (cl-repository-packager/publisher:publish-package
    "http://localhost:5050" "cl-systems/string-tools" "1.0.0" result))

;; Install and use from another session
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "http://localhost:5050")
(cl-repo:load-system "string-tools")
(string-tools:kebab-case "HelloWorld")  ; => "hello-world"
```

## Teardown

```bash
docker compose down -v
```
