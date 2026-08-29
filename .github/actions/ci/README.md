# ci (canned install / test / publish)

Reads the checkout `.asd`. Do **not** copy `ci-install.lisp` / `ci-test.lisp` / `publish-checkout.lisp`.

```yaml
permissions:
  contents: read
  packages: read
steps:
  - uses: actions/checkout@v5
  - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
  - uses: egao1980/cl-repository/.github/actions/ci@main
    with:
      phase: install
  - uses: egao1980/cl-repository/.github/actions/ci@main
    with:
      phase: test
```

90% case — reusable workflow (OS matrix included):

```yaml
jobs:
  test:
    uses: egao1980/cl-repository/.github/workflows/test-system.yml@main
```

Publish:

```yaml
jobs:
  publish:
    uses: egao1980/cl-repository/.github/workflows/publish-source.yml@main
    with:
      version: ${{ inputs.version }}
    permissions:
      contents: read
      packages: write
```

## `.asd` `:cl-repo :ci`

Honest `:depends-on` + `foo/tests` is enough. Extras that are **not** in the asd:

```lisp
:properties
(:cl-repo
 (:ci (:with ("dissect" "cl-stack-ssl")
       :sources (("rove" :ql))
       :also-tests t
       :load-before-test ("cl-stack-ssl")
       :record-versions (("cl-stack-ssl" . "CL_STACK_SSL_VERSION")))))
```

| Key | Meaning |
|-----|---------|
| `:with` | CI-only systems for `ensure-system-dependencies` |
| `:sources` | Per-system source pins (`((name :ql) …)`) |
| `:also-tests` | Walk `system/tests` (default `t`) |
| `:load-before-test` | Extra `asdf:load-system` before `test-system` |
| `:record-versions` | Alist → `GITHUB_ENV` after install |

`:ci` is ignored by `auto-package-spec`.

## Hooks

If present, loaded **after** the client (so `cl-repo:` works):

```
scripts/ci/pre-install.lisp
scripts/ci/post-install.lisp
scripts/ci/pre-test.lisp
scripts/ci/post-test.lisp
scripts/ci/pre-publish.lisp
scripts/ci/post-publish.lisp
```

`pre-install` may push extras onto `cl-repository-ci-lib:*extra-with*` (event backend from env, etc.).

## Inputs

| Input | Default | |
|-------|---------|---|
| `phase` | required | `install` / `test` / `publish` |
| `system` | discover | Unique primary `*.asd`, or directory-name match |
| `with` | | Space-separated extras, merged with `:ci :with` |
| `version` | `.asd :version` | Publish tag |
| `packager-version` | `latest` | Packager OCI tag |

`shell: bash` (Windows; also required inside a job container — default there is `sh`).
Call `setup-lisp` in **this** job first (Ubuntu `ci-base` image, or install on the VM).

`run.lisp` is loaded in one `ros -l` before the packager exists. Keep
`cl-repository-packager/*` and `cl-oci-client/*` symbols in `publish.lisp`
(loaded after `%ensure-packager`). GitHub also forbids expressions in `uses:`
— reusable workflows pin composite actions at `@main`.
