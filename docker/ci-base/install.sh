#!/usr/bin/env bash
# Bake Roswell + SBCL + oras + cl-repository-client into the CI job image.
# Invoked from docker/ci-base/Dockerfile. Not used on the runner VM.
set -Eeuo pipefail

SBCL_VERSION="${SBCL_VERSION:-2.6.7}"
ROSWELL_VERSION="${ROSWELL_VERSION:-26.02.116}"
CLIENT_VERSION="${CLIENT_VERSION:-latest}"
ORAS_VERSION="${ORAS_VERSION:-1.2.3}"
PREFIX="${ROSWELL_INSTALL_DIR:-/usr/local}"
CI_HOME="${CL_CI_HOME:-/opt/cl-ci}"
CLIENT_DEST="${CL_REPOSITORY_DEST:-${CI_HOME}/cl-repository}"

arch="$(uname -m)"
case "${arch}" in
  x86_64)  ros_arch="x86_64"; oras_arch="amd64" ;;
  aarch64) ros_arch="arm64";  oras_arch="arm64" ;;
  arm64)   ros_arch="arm64";  oras_arch="arm64" ;;
  *) echo "unsupported arch: ${arch}" >&2; exit 1 ;;
esac

mkdir -p "${CI_HOME}" "${CLIENT_DEST}"
export HOME="${CI_HOME}"
export ROSWELL_INSTALL_DIR="${PREFIX}"

# Release downloads: retries, and GITHUB_TOKEN (a build secret) for github.com.
# GitHub throttles unauthenticated requests first; a bare curl 504'd this build.
# shellcheck source=/dev/null
export CL_REPO_CI_DOWNLOADS=/tmp/cl-repo-ci-downloads
source /tmp/fetch.sh

# --- oras ---
oras_tgz="oras_${ORAS_VERSION}_linux_${oras_arch}.tar.gz"
oras_file="$(fetch "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${oras_tgz}" "${oras_tgz}")"
tar -xzf "${oras_file}" -C /usr/local/bin oras
oras version

# --- Roswell (prebuilt tarball; not install-for-ci.sh — that assumes a GH runner) ---
ros_tbz="roswell-${ROSWELL_VERSION}-linux-${ros_arch}.tar.bz2"
ros_file="$(fetch "https://github.com/roswell/roswell/releases/download/v${ROSWELL_VERSION}/${ros_tbz}" "${ros_tbz}")"
mkdir -p /tmp/roswell
tar -xjf "${ros_file}" -C /tmp/roswell --strip-components=1
make -C /tmp/roswell install
rm -rf /tmp/roswell /tmp/cl-repo-ci-downloads
command -v ros

# --- SBCL --- (ros fetches sbcl-bin_uri.tsv + the tarball itself: retry)
for attempt in 1 2 3 4 5 6; do
  if ros install "sbcl-bin/${SBCL_VERSION}" && ros use "sbcl-bin/${SBCL_VERSION}"; then
    break
  fi
  [[ "${attempt}" -lt 6 ]] || { echo "ros install sbcl-bin/${SBCL_VERSION} failed after retries" >&2; exit 1; }
  echo "ros install sbcl-bin/${SBCL_VERSION} failed (attempt ${attempt}); retrying..." >&2
  rm -rf "${HOME}"/.roswell/impls/*/*/sbcl-bin/"${SBCL_VERSION}" /root/.roswell/impls/*/*/sbcl-bin/"${SBCL_VERSION}"
  sleep $((5 * 2 ** attempt))
done
ros -e '(format t "~&~A ~A~%" (lisp-implementation-type) (lisp-implementation-version))' -q

# --- cl-repository-client + qlfile deps (same script as the composite action) ---
export CL_REPOSITORY_CLIENT_VERSION="${CLIENT_VERSION}"
export CL_REPOSITORY_DEST="${CLIENT_DEST}"
export GITHUB_WORKSPACE="${CI_HOME}/workspace"
mkdir -p "${GITHUB_WORKSPACE}"
# Image build has no GITHUB_ENV; setup-client.sh still writes client-dir to stdout.
# oras login (when the build secret is set) writes credentials under
# DOCKER_CONFIG: keep that out of the image's HOME and delete it afterwards.
export DOCKER_CONFIG=/tmp/cl-ci-docker-config
mkdir -p "${DOCKER_CONFIG}"
bash /tmp/setup-client.sh
rm -rf "${DOCKER_CONFIG}"
unset DOCKER_CONFIG

client_dir=""
for d in "${CLIENT_DEST}"/cl-oci-* "${CLIENT_DEST}"/cl-repository-client-*; do
  if [[ -d "${d}" && -f "${d}/cl-repository-client.asd" ]]; then
    client_dir="${d}"
    break
  fi
done
if [[ -z "${client_dir}" ]]; then
  echo "cl-repository-client.asd not found under ${CLIENT_DEST}" >&2
  exit 1
fi

resolved="$(printf '%s' "${client_dir##*/}")"
resolved="${resolved#cl-oci-}"
resolved="${resolved#cl-repository-client-}"

# ros(1) uses passwd home, not $HOME. Root → /root/.roswell even if HOME=/opt/cl-ci.
ros_home="${HOME}/.roswell"
if [[ -d /root/.roswell/impls ]]; then
  ros_home=/root/.roswell
fi
if [[ "${ros_home}" != "${CI_HOME}/.roswell" && ! -e "${CI_HOME}/.roswell" ]]; then
  ln -sfn "${ros_home}" "${CI_HOME}/.roswell"
fi

cat > "${CI_HOME}/image.env" <<EOF
CL_CI_IMAGE=1
CL_CI_SBCL_VERSION=${SBCL_VERSION}
CL_CI_ROSWELL_VERSION=${ROSWELL_VERSION}
CL_CI_ROSWELL_DIR=${ros_home}
CL_REPOSITORY_CLIENT_VERSION=${resolved}
CL_REPOSITORY_DEST=${CLIENT_DEST}
CL_REPOSITORY_CLIENT_DIR=${client_dir}
EOF
touch "${CI_HOME}/ok"

# The build secret must not survive into a layer.
if [[ -n "${GITHUB_TOKEN:-}" ]] && grep -rqsF -- "${GITHUB_TOKEN}" "${CI_HOME}" /root /usr/local/etc 2>/dev/null; then
  echo "GITHUB_TOKEN found in the image tree" >&2
  exit 1
fi

# Prove the baked client loads without the checkout tree.
CL_REPOSITORY_DEST="${CLIENT_DEST}" ros \
  -e '(asdf:initialize-source-registry (list :source-registry (list :tree (uiop:ensure-directory-pathname (uiop:getenv "CL_REPOSITORY_DEST"))) :ignore-inherited-configuration))' \
  -e '(asdf:load-system "cl-repository-client")' \
  -e '(format t "~&ci-base client from ~a~%" (asdf:system-source-directory "cl-repository-client"))' \
  -q
