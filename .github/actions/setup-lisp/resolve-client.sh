#!/usr/bin/env bash
# Resolve cl-repository-client :latest (or a pin) to a semver for the cache key.
# Does not pull layers.
set -Eeuo pipefail

IMAGE="${CL_REPOSITORY_CLIENT_IMAGE:-ghcr.io/egao1980/cl-repository/cl-repository-client}"
VERSION="${CL_REPOSITORY_CLIENT_VERSION:-latest}"
TOKEN="${GITHUB_TOKEN:-}"
ACTOR="${GITHUB_ACTOR:-}"

nocr() { printf '%s' "${1//$'\r'/}"; }

PY=""
for cand in python3 python; do
  if command -v "${cand}" >/dev/null 2>&1; then
    PY="${cand}"
    break
  fi
done
: "${PY:?python3 is required to parse OCI manifests}"

if [[ -n "${TOKEN}" ]]; then
  printf '%s\n' "${TOKEN}" | oras login ghcr.io -u "${ACTOR:-oras}" --password-stdin >/dev/null
fi

parse_ver() {
  "${PY}" -c '
import json, sys
d = json.load(sys.stdin)
ann = d.get("annotations") or {}
ver = (ann.get("org.opencontainers.image.version") or "").replace("\r", "")
sys.stdout.buffer.write(ver.encode("utf-8") + b"\n")
'
}

want="$(nocr "${VERSION}")"
if [[ -z "${want}" || "${want}" == latest ]]; then
  json="$(oras manifest fetch "${IMAGE}:latest")"
  ver="$(nocr "$(printf '%s\n' "${json}" | parse_ver)")"
  if [[ -z "${ver}" ]]; then
    echo "resolve-client: ${IMAGE}:latest has no org.opencontainers.image.version" >&2
    exit 1
  fi
  resolved="${ver}"
else
  resolved="${want}"
fi

{
  printf 'client-version=%s\n' "${resolved}"
} >> "${GITHUB_OUTPUT}"

echo "resolved ${IMAGE}:${VERSION} → ${resolved}"
