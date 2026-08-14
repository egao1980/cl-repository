# setup-roswell

Roswell (Unix `install-for-ci.sh` / Windows zip) + optional `sbcl-bin`. Pair with `setup-client`.

```yaml
- uses: actions/checkout@v5
- uses: egao1980/cl-repository/.github/actions/setup-client@main
- uses: egao1980/cl-repository/.github/actions/setup-roswell@main
  with:
    sbcl-version: ${{ env.SBCL_VERSION }}
    roswell-version: ${{ env.ROSWELL_VERSION }}
- run: ros -l scripts/ci-install.lisp -q
- run: ros -l scripts/ci-test.lisp -q
```

ECL/CCL jobs: `install-sbcl: "false"`, then `ros install ecl` / `ccl-bin` as today.

Native `publish-oci.yml` uses the same three actions + `ci-install.lisp` (not a second QL bootstrap / `CI_INSTALL_DEPS_ONLY`).
