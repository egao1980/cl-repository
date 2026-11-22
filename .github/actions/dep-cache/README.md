# dep-cache

Caches what the `ci` install and test phases build: the cl-repo installed-systems tree (`~/.local/share/cl-repository`) and ASDF's fasl cache (`$XDG_CACHE_HOME/common-lisp`). A cold install of a project with about 80 dependencies took 10–15 minutes: resolution, OCI pulls, then compiling everything. A warm job finds the systems already installed and the fasls current ([#136](https://github.com/egao1980/cl-repository/issues/136)).

`test-system.yml` and `test-system-impl.yml` use it by default. Pass `dep-cache: "false"` to install cold every run.

```yaml
- uses: egao1980/cl-repository/.github/actions/setup-lisp@main
- uses: egao1980/cl-repository/.github/actions/dep-cache@main
  id: dep-cache
- id: install
  uses: egao1980/cl-repository/.github/actions/ci@main
  with: { phase: install }
- uses: egao1980/cl-repository/.github/actions/ci@main
  with: { phase: test }
- uses: egao1980/cl-repository/.github/actions/dep-cache@main
  if: always() && steps.install.outcome == 'success'
  with:
    mode: save
    key: ${{ steps.dep-cache.outputs.key }}
    fasl: ${{ steps.dep-cache.outputs.fasl }}
    cache-hit: ${{ steps.dep-cache.outputs.cache-hit }}
```

**Key:** `<os>-<arch>-cl-deps-v1-<impl>-client-<client version>-<UTC day>-<hash of *.asd, cl-repo.lock, cl-repo.conf>`. A job restores the newest cache from the same day. So new dependency releases reach CI within a day, or at once when the project raises a minimum version in its `.asd`.

**Save after the tests,** even when they fail. The dependency fasls are compiled in the test phase, and `actions/cache`'s own post step saves only green jobs.

**Systems and fasls go into one cache.** The installer sets fresh mtimes on the sources it extracts, so fasls are only valid next to the exact tree they were compiled from.
