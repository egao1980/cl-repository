# Native Dependency Handling

## Layer Roles

| Role | Contents | Scope |
|------|----------|-------|
| `source` | CL source + .asd files | Universal |
| `native-library` | Prebuilt .so/.dylib/.dll | Platform overlay |
| `static-library` | .a/.lib for CFFI static linking (canary) | Platform overlay |
| `cffi-grovel-output` | Pre-groveled .cffi.lisp | Platform overlay (os+arch only) |
| `cffi-wrapper` | Compiled wrapper .so for inline C | Platform overlay |
| `headers` | C header files | Platform overlay or universal |
| `documentation` | Docs, man pages | Universal (optional) |
| `build-script` | Makefile/build.sh for from-source fallback | Universal (optional) |
| `<custom-role>` | Project-specific payloads | Author-defined |

Known roles map to conventional destinations (`native/`, `grovel-cache/`, `headers/`, `docs/`). Unknown/custom
roles are extracted according to tar paths and are accepted for forward compatibility.

## Overlay Schema

Use unified role-tagged overlay layers:

```lisp
(:platform (:os "linux" :arch "amd64")
 :layers ((:role "native-library"
           :files (("lib/linux-amd64/libfoo.so" . "libfoo.so")))
          (:role "cffi-grovel-output"
           :files (("grovel/linux-amd64/libfoo.cffi.lisp" . "libfoo.cffi.lisp")))
          (:role "custom-role"
           :files (("meta/linux-amd64/marker.txt" . "marker.txt")))))
```

Legacy compatibility is preserved: `:native-paths (...)` is still accepted and normalized into a
`native-library` layer.

## CFFI Integration

### Grovel Output Portability

CFFI grovel output is **OS+architecture dependent but CL-implementation-independent**. One grovel overlay per os/arch pair serves all CL implementations.

### Post-Install

The client only places files: shared objects under `<system-root>/native/`,
grovel output under `grovel-cache/`. **It writes and runs no init script.**

1. **The package loads its own natives at ASDF load.** Its first component (a
   `loader.lisp` or `ffi.lisp`) looks in `native/` (installed overlay), then
   `lib/<os>-<arch>/` (a checkout with built libraries), pushes that directory onto
   `cffi:*foreign-library-directories*`, and calls `cffi:load-foreign-library` on
   **absolute paths** (dependencies first, e.g. `libcrypto` before `libssl`), so a
   distro library with the same soname cannot win through a bare `dlopen`. Consumers
   need nothing beyond `(asdf:load-system "foo")`.
2. Redirect grovel-file ASDF components to use cached `.cffi.lisp` from `grovel-cache/`
3. For CFFI canary pattern: prebuilt libs work transparently
4. Falls back to from-source groveling if C compiler is available

Do **not** rely on `LD_LIBRARY_PATH` for overlay correctness — mid-process
`setenv` is ignored by the dynamic linker on Linux; absolute preload is the supported path.

Earlier clients generated a `cl-repo-init.lisp` per system and loaded every one
in the shared store before tests. That preloaded natives of unrelated projects
(on a developer machine, a library whose initialisers abort the process) and is
gone; `load-system-init-files` remains as a no-op for one release.


### Convention: asdf-native components, no `:overlays`

A system that declares its libraries as [asdf-native](https://github.com/egao1980/asdf-native)
components needs no hand-written `:overlays`:

```lisp
(defsystem "foo"
  :defsystem-depends-on ("asdf-native")
  :components ((:file "package")
               (:native-library "foo-cl")          ; loads libfoo-cl.* at ASDF load
               (:file "ffi")))
```

- **Platforms.** Each `lib/<os>-<arch>/` directory (`linux-amd64`, `darwin-arm64`, …) becomes
  that platform's overlay. Every file in it ships into `native/`, so libraries the
  component's library depends on go along.
- **Check.** Each platform must hold a file-name variant of every non-optional
  `:native-library`, or packaging fails. The CI native publish runs the same check
  on its artifact directories.
- **Options** in `:properties (:cl-repo …)`:
  - `:native-platforms ("linux-amd64" ("windows-amd64" . "out/win/"))` is a strict list. A
    listed platform without a directory is an error. A pair may map to its own directory.
  - `:native-directory "build/{pair}/"` sets the template (`{pair}`, `{os}`, `{arch}`).
  - Explicit `:overlays` for platforms replace the derived ones. Named overlays (`cuda`)
    are added on top of them.
- `:cffi-libraries` defaults to the component names.

`:defsystem-depends-on` systems are read from the `.asd` without evaluating it and
installed from OCI before ASDF loads the file (`cl-repo sync`/`test`, the CI action and
the native publish).

### Config Blob Metadata

`cffi-libraries` in config blob maps each foreign library to:
- `define-foreign-library`: fully qualified CFFI symbol
- `canary`: function name to detect if library is already loaded
- `search-path`: relative path pushed to `cffi:*foreign-library-directories*`

## Build Matrix

| Dimension | Examples | When |
|-----------|----------|------|
| OS | linux, darwin, windows | Always for overlays |
| Architecture | amd64, arm64 | Always for overlays |
| CL Implementation | sbcl, ccl, ecl | Only for impl-specific code |
| OS Version | ubuntu-20.04, macos-14 | For ABI-sensitive native libs |

Most packages only need os+arch. CL implementation dimension only for precompiled FASLs or impl-specific native code.
