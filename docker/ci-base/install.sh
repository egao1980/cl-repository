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

# --- oras ---
oras_tgz="oras_${ORAS_VERSION}_linux_${oras_arch}.tar.gz"
curl -fsSL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${oras_tgz}" \
  -o "/tmp/${oras_tgz}"
tar -xzf "/tmp/${oras_tgz}" -C /usr/local/bin oras
rm -f "/tmp/${oras_tgz}"
oras version

# --- Roswell (prebuilt tarball; not install-for-ci.sh — that assumes a GH runner) ---
ros_tbz="roswell-${ROSWELL_VERSION}-linux-${ros_arch}.tar.bz2"
curl -fsSL "https://github.com/roswell/roswell/releases/download/v${ROSWELL_VERSION}/${ros_tbz}" \
  -o "/tmp/${ros_tbz}"
mkdir -p /tmp/roswell
tar -xjf "/tmp/${ros_tbz}" -C /tmp/roswell --strip-components=1
make -C /tmp/roswell install
rm -rf /tmp/roswell "/tmp/${ros_tbz}"
command -v ros

# --- SBCL ---
ros install "sbcl-bin/${SBCL_VERSION}"
ros use "sbcl-bin/${SBCL_VERSION}"
ros -e '(format t "~&~A ~A~%" (lisp-implementation-type) (lisp-implementation-version))' -q

# --- cl-repository-client + qlfile deps (same script as the composite action) ---
export CL_REPOSITORY_CLIENT_VERSION="${CLIENT_VERSION}"
export CL_REPOSITORY_DEST="${CLIENT_DEST}"
export GITHUB_WORKSPACE="${CI_HOME}/workspace"
mkdir -p "${GITHUB_WORKSPACE}"
# Image build has no GITHUB_ENV; setup-client.sh still writes client-dir to stdout.
bash /tmp/setup-client.sh

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

# Prove the baked client loads without the checkout tree.
export CL_SOURCE_REGISTRY="${CLIENT_DEST}//:"
ros -e '(asdf:load-system "cl-repository-client")' \
    -e '(format t "~&ci-base client from ~a~%" (asdf:system-source-directory "cl-repository-client"))' \
    -q
