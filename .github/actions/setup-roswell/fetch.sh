# shellcheck shell=bash
# fetch URL NAME → path of NAME in the CI download cache, downloading it once.
#
# Release assets come from GitHub's CDN, which can answer 504 for long
# stretches (2026-11-08). A cached copy is used without touching the network;
# otherwise curl retries every error with backoff. The file only lands in the
# cache once it downloaded completely, so a partial file is never reused.

CL_REPO_CI_DOWNLOADS="${CL_REPO_CI_DOWNLOADS:-${HOME}/.cache/cl-repo-ci/downloads}"

fetch() {
  local url="$1" name="$2"
  local dest="${CL_REPO_CI_DOWNLOADS}/${name}"
  mkdir -p "${CL_REPO_CI_DOWNLOADS}"
  if [[ -s "${dest}" ]]; then
    echo "fetch: ${name} from cache" >&2
  else
    echo "fetch: ${url}" >&2
    # GitHub throttles unauthenticated traffic first (2026-11-08 incident:
    # "timeouts for some unauthenticated users"). Send the job token to
    # github.com only; curl drops it on the redirect to the asset CDN.
    local -a auth=()
    if [[ -n "${GITHUB_TOKEN:-}" && "${url}" == https://github.com/* ]]; then
      auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi
    curl -fsSL --retry 8 --retry-all-errors --retry-delay 5 --retry-max-time 900 \
         --connect-timeout 30 ${auth[@]+"${auth[@]}"} -o "${dest}.part" "${url}"
    mv -f "${dest}.part" "${dest}"
  fi
  printf '%s\n' "${dest}"
}
