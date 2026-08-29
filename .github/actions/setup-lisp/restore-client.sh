#!/usr/bin/env bash
# Export CL_* from a restored .cl-repository cache. No oras pull.
set -Eeuo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
DEST_IN="${CL_REPOSITORY_DEST:-.cl-repository}"
WANT_VER="${CL_REPOSITORY_CLIENT_VERSION:-}"

if [[ "${DEST_IN}" = /* ]]; then
  DEST="${DEST_IN}"
else
  DEST="${WORKSPACE}/${DEST_IN}"
fi

if command -v cygpath >/dev/null 2>&1; then
  WORKSPACE="$(cygpath -u "${WORKSPACE}")"
  DEST="$(cygpath -u "${DEST}")"
fi

find_client_dir() {
  local dest="$1" d
  for d in "${dest}"/cl-oci-* "${dest}"/cl-repository-client-*; do
    if [[ -d "${d}" && -f "${d}/cl-repository-client.asd" ]]; then
      printf '%s\n' "${d}"
      return 0
    fi
  done
  d="$(find "${dest}" -maxdepth 3 -name 'cl-repository-client.asd' -print -quit 2>/dev/null || true)"
  [[ -n "${d}" ]] || return 1
  dirname "${d}"
}

CLIENT_DIR="$(find_client_dir "${DEST}" || true)"
if [[ -z "${CLIENT_DIR}" ]]; then
  echo "valid=false" >> "${GITHUB_OUTPUT}"
  echo "restore-client: no cl-repository-client.asd under ${DEST}; will pull"
  exit 0
fi

if command -v cygpath >/dev/null 2>&1; then
  CLIENT_DIR="$(cygpath -m "${CLIENT_DIR}")"
  DEST="$(cygpath -m "${DEST}")"
  WORKSPACE="$(cygpath -m "${WORKSPACE}")"
  SOURCE_REGISTRY="${WORKSPACE}//;${DEST}//;"
else
  SOURCE_REGISTRY="${WORKSPACE}//:${DEST}//:"
fi

{
  printf 'CL_REPOSITORY_CLIENT_DIR=%s\n' "${CLIENT_DIR}"
  printf 'CL_REPOSITORY_CLIENT_VERSION=%s\n' "${WANT_VER}"
  printf 'CL_REPOSITORY_DEST=%s\n' "${DEST}"
  printf 'CL_SOURCE_REGISTRY=%s\n' "${SOURCE_REGISTRY}"
} >> "${GITHUB_ENV}"

{
  printf 'client-dir=%s\n' "${CLIENT_DIR}"
  printf 'client-version=%s\n' "${WANT_VER}"
  printf 'dest=%s\n' "${DEST}"
  printf 'source-registry=%s\n' "${SOURCE_REGISTRY}"
  printf 'valid=true\n'
} >> "${GITHUB_OUTPUT}"

echo "restore-client: ${CLIENT_DIR} (${WANT_VER})"
