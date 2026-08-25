# setup-roswell

Roswell (Unix `install-for-ci.sh` / Windows zip) + optional `sbcl-bin`. Pair with `setup-client`.

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
