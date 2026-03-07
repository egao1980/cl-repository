# System Requirements

## cl-oci

Pure data model library. Zero I/O dependencies.

- CLOS classes: digest, descriptor, platform, manifest, image-index, config
- Media type constants (OCI standard + CL-specific)
- Annotation key constants (OCI standard + `dev.common-lisp.*`)
- JSON serialization/deserialization via yason
- SHA256 digest computation via ironclad
- Dependencies: yason, ironclad, babel, alexandria

## cl-oci-client

OCI Distribution Spec v1.1 HTTP client.

- Registry class with base URL construction
- Authentication: Bearer token, Basic auth
- Pull: manifests, blobs, HEAD checks
- Push: monolithic blob upload, manifest PUT, blob mount
- Content discovery: tag listing, referrers API
- Dependencies: cl-oci, dexador, quri, cl-ppcre, cl-base64

## cl-repository-packager

ASDF plugin and build matrix for creating OCI artifacts.

- Layer builder: tar+gzip from directories/files
- Manifest builder: assemble OCI manifest from config + layers
- Build matrix: platform iteration, overlay generation, Image Index assembly
- ASDF `package-op` integration
- Publisher: push blobs + manifests + index to registry
- Dependencies: cl-oci-client, salza2, flexi-streams

## cl-repository-client

Client library for installing packages from OCI registries.

- Platform resolver: detect local OS/arch/impl via trivial-features
- Installer: pull + extract layers to ASDF-loadable directory tree
- Lockfile: generation, verification, update
- ASDF integration: source-registry configuration, init file loading
- High-level commands: install, update, list, search, info
- Dependencies: cl-oci-client, chipz, flexi-streams, trivial-features

## cl-repository-ql-exporter

Quicklisp/Ultralisp to OCI bulk exporter.

- Dist parser: parse distinfo.txt, releases.txt, systems.txt
- ASD introspector: extract metadata from .asd without loading
- Repackager: convert QL archive to OCI layers + manifest + index
- Incremental sync: HEAD-check based skip logic
- Exporter: orchestrate download -> repackage -> push pipeline
- Dependencies: cl-oci-client, cl-repository-packager, dexador
