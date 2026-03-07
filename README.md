# CL Repository

OCI-based distribution system for Common Lisp packages.

Packages are standard OCI artifacts pushable to any OCI-compliant registry (GHCR, Docker Hub, Quay, etc.) and pullable by any OCI client (oras, crane, skopeo) or the included CL-native client.

## Systems

| System | Description |
|--------|-------------|
| `cl-oci` | CLOS library modeling OCI Image and Distribution specifications |
| `cl-oci-client` | OCI Distribution Spec v1.1 HTTP client |
| `cl-repository-packager` | ASDF plugin + build matrix for packaging CL systems as OCI artifacts |
| `cl-repository-client` | Client library + CLI for installing packages from OCI registries |
| `cl-repository-ql-exporter` | Quicklisp/Ultralisp to OCI artifact bulk exporter |

## Quick Start

```lisp
;; Load a system from configured OCI registries (like ql:quickload)
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "cl-systems")
(cl-repo:load-system "alexandria")

;; Package and publish a system (reads OCI config from .asd :properties)
(asdf:load-system "cl-repository-packager")
(asdf:operate 'cl-repository-packager:package-op "my-system")
```

### CLI

```sh
cl-repo install alexandria
cl-repo install cffi:0.24.1
cl-repo publish
cl-repo ql-export https://beta.quicklisp.org/dist/quicklisp.txt --registry ghcr.io --namespace cl-systems
```

### Embedded OCI Config in .asd

```lisp
(defsystem "my-lib"
  :version "1.0.0"
  :depends-on ("cffi")
  :properties (:cl-repo (:cffi-libraries ("libfoo")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :native-paths ("lib/libfoo.so")))))
  :components (...))
```

See [docs/spec.md](docs/spec.md) for the full specification.

## Examples

| Example | Description |
|---------|-------------|
| [01-basic-usage](examples/01-basic-usage/) | Load systems from REPL and CLI |
| [02-publish-system](examples/02-publish-system/) | Build and publish a CL system |
| [03-quicklisp-mirror](examples/03-quicklisp-mirror/) | Mirror Quicklisp to OCI |
| [04-native-deps](examples/04-native-deps/) | CFFI + platform overlays |
| [05-ci-workflow](examples/05-ci-workflow/) | GitHub Actions CI/CD |
| [06-asd-embedded-config](examples/06-asd-embedded-config/) | OCI config embedded in .asd |

## Development

Requires [Roswell](https://github.com/roswell/roswell) and [qlot](https://github.com/fukamachi/qlot).

```sh
qlot install
qlot exec ros run
```

Or use the devcontainer (VS Code / Cursor with `egao1980/features` + `alive`).

### Running Tests

Unit tests:

```sh
qlot exec ros -e '(asdf:test-system "cl-oci")'
qlot exec ros -e '(asdf:test-system "cl-oci-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-packager")'
qlot exec ros -e '(asdf:test-system "cl-repository-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-ql-exporter")'
```

Integration tests (requires Docker OCI registry at `localhost:5050`):

```sh
docker run -d -p 5050:5000 --name oci-registry registry:2
qlot exec ros -e '(asdf:test-system "cl-repository-integration-tests")'
```

## License

MIT
