# setup-roswell

Roswell (Linux `install-for-ci.sh` / macOS Homebrew / Windows zip) + optional pinned `sbcl-bin`. Prefer `setup-lisp` (uses the `ci-base` job container on Ubuntu; falls back to this action on a VM). Pair with `setup-client` if you compose the install path yourself.

macOS does **not** run `install-for-ci.sh`: that script's `ros use sbcl-bin` (unversioned) flakes with `unable to use 'sbcl-bin'` on GHA `macos-latest`. We `brew install roswell`, then `ros install sbcl-bin/<pin>` with retries, and fall back to Homebrew `sbcl` + `ros use sbcl/system`.

```yaml
- uses: actions/checkout@v5
- uses: egao1980/cl-repository/.github/actions/setup-client@main
- uses: egao1980/cl-repository/.github/actions/setup-roswell@main
  with:
    sbcl-version: ${{ env.SBCL_VERSION }}
    roswell-version: ${{ env.ROSWELL_VERSION }}
- uses: egao1980/cl-repository/.github/actions/ci@main
  with: { phase: install }
- uses: egao1980/cl-repository/.github/actions/ci@main
  with: { phase: test }
```

Prefer `test-system.yml` for the 90% case. ECL/CCL jobs: `install-sbcl: "false"`, then `ros install ecl` / `ccl-bin` as today.

Native `publish-oci.yml` uses setup-client + setup-roswell + `ci` (`phase: install`), not a second QL bootstrap.
