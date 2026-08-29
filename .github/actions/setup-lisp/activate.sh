#!/usr/bin/env bash
# Wire a baked ci-base image (or a restored ~/.roswell cache) for later ros / ASDF steps.
# GHA remaps HOME to /github/home inside job containers — impls live under /opt/cl-ci.
set -Eeuo pipefail

CI_HOME="${CL_CI_HOME:-/opt/cl-ci}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"

if command -v cygpath >/dev/null 2>&1; then
  WORKSPACE="$(cygpath -m "${WORKSPACE}")"
fi

if [[ -f "${CI_HOME}/ok" && -f "${CI_HOME}/image.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1090
  source "${CI_HOME}/image.env"
  set +a

  # Roswell uses passwd home (/root), not $HOME. GHA remaps HOME to /github/home.
  ros_home="${CL_CI_ROSWELL_DIR:-}"
  if [[ -z "${ros_home}" || ! -d "${ros_home}/impls" ]]; then
    if [[ -d /root/.roswell/impls ]]; then
      ros_home=/root/.roswell
    elif [[ -d "${CI_HOME}/.roswell/impls" ]]; then
      ros_home="${CI_HOME}/.roswell"
    fi
  fi
  if [[ -n "${ros_home}" && -d "${ros_home}/impls" ]]; then
    mkdir -p "${HOME}"
    if [[ ! -e "${HOME}/.roswell" ]]; then
      ln -sfn "${ros_home}" "${HOME}/.roswell"
    fi
    echo "${ros_home}/bin" >> "${GITHUB_PATH}"
  fi
  echo "/usr/local/bin" >> "${GITHUB_PATH}"

  dest="${CL_REPOSITORY_DEST}"
  client_dir="${CL_REPOSITORY_CLIENT_DIR}"
  if command -v cygpath >/dev/null 2>&1; then
    dest="$(cygpath -m "${dest}")"
    client_dir="$(cygpath -m "${client_dir}")"
    registry="${WORKSPACE}//;${dest}//;"
  else
    registry="${WORKSPACE}//:${dest}//:"
  fi

  {
    printf 'CL_CI_IMAGE=1\n'
    printf 'CL_REPOSITORY_CLIENT_DIR=%s\n' "${client_dir}"
    printf 'CL_REPOSITORY_CLIENT_VERSION=%s\n' "${CL_REPOSITORY_CLIENT_VERSION}"
    printf 'CL_REPOSITORY_DEST=%s\n' "${dest}"
    printf 'CL_SOURCE_REGISTRY=%s\n' "${registry}"
  } >> "${GITHUB_ENV}"

  {
    printf 'client-dir=%s\n' "${client_dir}"
    printf 'client-version=%s\n' "${CL_REPOSITORY_CLIENT_VERSION}"
    printf 'dest=%s\n' "${dest}"
    printf 'source-registry=%s\n' "${registry}"
    printf 'image=true\n'
  } >> "${GITHUB_OUTPUT}"

  printf 'ci-base: sbcl=%s ros=%s client=%s dest=%s\n' \
    "${CL_CI_SBCL_VERSION:-}" "${CL_CI_ROSWELL_VERSION:-}" \
    "${CL_REPOSITORY_CLIENT_VERSION}" "${dest}"
  exit 0
fi

printf 'image=false\n' >> "${GITHUB_OUTPUT}"
echo "ci-base marker missing; caller should run setup-roswell + setup-client"
