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
