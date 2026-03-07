# CL Repository Requirements

## Problem Statement

Common Lisp lacks a standard distribution system comparable to PyPI, crates.io, or npm. Existing solutions (Quicklisp, OCICL) are limited — particularly in handling multiplatform native library dependencies.

## Goals

1. **Standard OCI distribution**: packages are OCI artifacts fetchable by any OCI client
2. **Multiplatform native deps**: overlay manifests per OS/arch/implementation with prebuilt shared libraries, pre-groveled CFFI bindings, headers
3. **ASDF-native**: extracted packages are immediately ASDF-loadable with no extra configuration
4. **Minimal dependencies**: balance functionality with portability, avoid heavy frameworks
5. **Backward compatible**: pure-Lisp packages need only a universal manifest (no overlays)
6. **Ecosystem bootstrapping**: bulk export from Quicklisp/Ultralisp to seed OCI registries

## Non-Goals

- Custom registry server implementation (leverage existing OCI registries)
- Binary FASL distribution (implementation-specific, fragile across versions)
- Package signing (defer to OCI registry features like cosign/notary)
