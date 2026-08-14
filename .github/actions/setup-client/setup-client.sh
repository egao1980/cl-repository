#!/usr/bin/env bash
# Pull cl-repository-client + its Lisp deps from OCI. No Quicklisp.
# Client image: :latest is a system-name anchor → semver.
# cl-systems packages often have no :latest anchor (SKIP_CATALOG) → highest version tag.
set -Eeuo pipefail

IMAGE="${CL_REPOSITORY_CLIENT_IMAGE:-ghcr.io/egao1980/cl-repository/cl-repository-client}"
VERSION="${CL_REPOSITORY_CLIENT_VERSION:-latest}"
SYSTEMS_NS="${CL_REPOSITORY_SYSTEMS:-ghcr.io/egao1980/cl-systems}"
PULL_DEPS="${CL_REPOSITORY_PULL_DEPS:-true}"
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
DEST_IN="${CL_REPOSITORY_DEST:-.cl-repository}"
TOKEN="${GITHUB_TOKEN:-}"
ACTOR="${GITHUB_ACTOR:-}"

if [[ "${DEST_IN}" = /* ]]; then
  DEST="${DEST_IN}"
else
  DEST="${WORKSPACE}/${DEST_IN}"
fi

# Git Bash tar/oras on windows-latest cannot -C a D:\… path (GITHUB_WORKSPACE).
if command -v cygpath >/dev/null 2>&1; then
  WORKSPACE="$(cygpath -u "${WORKSPACE}")"
  DEST="$(cygpath -u "${DEST}")"
fi

CLIENT_NS="${IMAGE%/*}"
PY=""
for cand in python3 python; do
  if command -v "${cand}" >/dev/null 2>&1; then
    PY="${cand}"
    break
  fi
done
: "${PY:?python3 is required to parse OCI manifests}"

log() { printf '%s\n' "$*"; }
die() { printf 'setup-client: %s\n' "$*" >&2; exit 1; }
# Git Bash on Windows: Python print() and some pipes use CRLF. Strip CR so
# oras refs stay "image:0.16.0" rather than "image:0.16.0\r".
nocr() { printf '%s' "${1//$'\r'/}"; }

oras_login() {
  [[ -z "${TOKEN}" ]] && return 0
  local user="${ACTOR:-oras}"
  printf '%s\n' "${TOKEN}" | oras login ghcr.io -u "${user}" --password-stdin >/dev/null
}

parse_manifest() {
  "${PY}" -c '
import json, sys
def emit(v):
    sys.stdout.buffer.write(str(v or "").replace("\r", "").encode("utf-8") + b"\n")
d = json.load(sys.stdin)
ann = d.get("annotations") or {}
emit(ann.get("org.opencontainers.image.version") or "")
emit(ann.get("dev.common-lisp.alias-for") or "")
emit(d.get("artifactType") or "")
emit(ann.get("dev.common-lisp.system.depends-on") or "")
'
}

load_manifest_fields() {
  local json="$1"
  {
    read -r MF_VER
    read -r MF_ALIAS
    read -r MF_ATYPE
    read -r MF_DEPS || true
  } < <(printf '%s\n' "${json}" | parse_manifest)
  MF_VER="$(nocr "${MF_VER}")"
  MF_ALIAS="$(nocr "${MF_ALIAS}")"
  MF_ATYPE="$(nocr "${MF_ATYPE}")"
  MF_DEPS="$(nocr "${MF_DEPS}")"
}

highest_tag() {
  # stdin: oras repo tags; stdout: best pull tag (version-like preferred)
  "${PY}" -c '
import re, sys
def emit(v):
    sys.stdout.buffer.write(str(v).replace("\r", "").encode("utf-8") + b"\n")
tags = [t.strip() for t in sys.stdin if t.strip() and t.strip() != "latest"]
def key(t):
    # Whole tag must be a semver. SHAs like 677cabae… start with digits and
    # must not outrank 0.24.1.
    m = re.fullmatch(r"v?(\d+(?:\.\d+)*)", t)
    if not m:
        return None
    return tuple(int(x) for x in m.group(1).split("."))
vers = [(key(t), t) for t in tags]
vers = [(k, t) for k, t in vers if k is not None]
if vers:
    vers.sort()
    emit(vers[-1][1])
elif tags:
    emit(tags[-1])
'
}

is_anchor() {
  [[ "${1}" == *system-name* ]]
}

skip_dep() {
  local name="$1"
  case "${name}" in
    ""|asdf|uiop|sb-*|sbcl-*|rove|archive) return 0 ;;
  esac
  [[ "${name}" == */* ]]
}

oci_pkg_name() {
  # GHCR paths cannot contain '+'; packager maps cl+ssl → cl-plus-ssl.
  printf '%s' "${1//+/-plus-}"
}

fetch_manifest() {
  oras manifest fetch "$1"
}

# Sets RESOLVED_REF, RESOLVED_VER, RESOLVED_DEPS (comma-separated)
resolve_system() {
  local image="$1"   # registry/ns/name
  local want="${2:-latest}"
  local json ver alias atype deps tag

  RESOLVED_REF=""
  RESOLVED_VER=""
  RESOLVED_DEPS=""

  if [[ -z "${want}" || "${want}" == latest ]]; then
    if json="$(fetch_manifest "${image}:latest" 2>/dev/null)"; then
      load_manifest_fields "${json}"
      ver="${MF_VER}"; alias="${MF_ALIAS}"; atype="${MF_ATYPE}"; deps="${MF_DEPS}"
      if is_anchor "${atype}"; then
        [[ -n "${ver}" ]] || die "anchor ${image}:latest has no org.opencontainers.image.version"
        if fetch_manifest "${image}:${ver}" >/dev/null 2>&1; then
          tag="${ver}"
        elif [[ -n "${alias}" ]] && fetch_manifest "${CLIENT_NS}/${alias}:${ver}" >/dev/null 2>&1; then
          RESOLVED_REF="${CLIENT_NS}/${alias}:${ver}"
          RESOLVED_VER="${ver}"
          json="$(fetch_manifest "${RESOLVED_REF}")"
          load_manifest_fields "${json}"
          RESOLVED_DEPS="${MF_DEPS}"
          return 0
        else
          die "resolved ${image}:latest → ${ver}, but ${image}:${ver} is missing"
        fi
      else
        tag="${ver:-latest}"
        if [[ "${tag}" == latest ]]; then
          :
        fi
      fi
    else
      tag="$(nocr "$(oras repo tags "${image}" 2>/dev/null | highest_tag || true)")"
      [[ -n "${tag}" ]] || return 1
    fi
  else
    tag="$(nocr "${want}")"
  fi

  json="$(fetch_manifest "${image}:${tag}")" || return 1
  load_manifest_fields "${json}"
  RESOLVED_REF="${image}:${tag}"
  RESOLVED_VER="${MF_VER:-${tag}}"
  RESOLVED_DEPS="${MF_DEPS}"
}

pull_extract() {
  local ref="$1"
  local dest="$2"
  local tmp attempt=1 max=4 delay=4
  mkdir -p "${dest}"
  while true; do
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/cl-repo-pull.XXXXXX")"
    if oras pull "${ref}" -o "${tmp}"; then
      break
    fi
    rm -rf "${tmp}"
    if [[ "${attempt}" -ge "${max}" ]]; then
      die "oras pull failed after ${max} attempts: ${ref}"
    fi
    log "  oras pull retry ${attempt}/${max} in ${delay}s: ${ref}"
    sleep "${delay}"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
  shopt -s nullglob
  local f
  for f in "${tmp}"/*.tar.gz; do
    tar -xzf "${f}" -C "${dest}"
  done
  shopt -u nullglob
  rm -rf "${tmp}"
}

qlfile_seeds() {
  local qlfile="$1"
  [[ -f "${qlfile}" ]] || return 0
  "${PY}" -c '
import sys
skip = {"rove", "archive"}
path = sys.argv[1]
out = []
with open(path, encoding="utf-8") as f:
    for raw in f:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        kind = parts[0]
        if kind == "ql" and len(parts) >= 2:
            name = parts[1]
        elif kind == "github" and len(parts) >= 2:
            name = parts[1].rsplit("/", 1)[-1]
        else:
            continue
        if name not in skip:
            out.append(name)
seen = set()
buf = sys.stdout.buffer
for n in out:
    if n not in seen:
        seen.add(n)
        buf.write(n.replace("\r", "").encode("utf-8") + b"\n")
' "${qlfile}"
}

find_client_dir() {
  local dest="$1"
  local d
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

system_extracted() {
  local dest="$1"
  local name="$2"
  find "${dest}" -name "${name}.asd" -print -quit | grep -q .
}

pull_system_tree() {
  local dest="$1"
  shift
  local -a queue=("$@")
  local seen=" "
  local name ns deps dep pulled qi oci_name pkg
  qi=0

  while [[ "${qi}" -lt "${#queue[@]}" ]]; do
    name="${queue[$qi]}"
    qi=$((qi + 1))
    [[ -n "${name}" ]] || continue
    skip_dep "${name}" && continue
    [[ "${seen}" == *" ${name} "* ]] && continue
    seen="${seen}${name} "

    if system_extracted "${dest}" "${name}"; then
      continue
    fi

    pulled=0
    deps=""
    oci_name="$(oci_pkg_name "${name}")"
    for pkg in "${oci_name}" "${name}"; do
      [[ -n "${pkg}" ]] || continue
      for ns in "${SYSTEMS_NS}" "${CLIENT_NS}"; do
        if resolve_system "${ns}/${pkg}" latest; then
          log "  oras pull ${RESOLVED_REF}"
          pull_extract "${RESOLVED_REF}" "${dest}"
          deps="${RESOLVED_DEPS}"
          pulled=1
          break 2
        fi
      done
      [[ "${pkg}" == "${name}" ]] && break
    done
    if [[ "${pulled}" -ne 1 ]]; then
      die "not in OCI: ${name} (tried ${SYSTEMS_NS}/{${oci_name},${name}} and ${CLIENT_NS}/{${oci_name},${name}})"
    fi
    if [[ -n "${deps}" ]]; then
      IFS=',' read -r -a dep_arr <<< "${deps}"
      for dep in "${dep_arr[@]}"; do
        dep="${dep// /}"
        [[ -n "${dep}" ]] || continue
        queue[${#queue[@]}]="${dep}"
      done
    fi
  done
}

# --- main ---
command -v oras >/dev/null 2>&1 || die "oras not on PATH"
oras_login

log "Resolving ${IMAGE}:${VERSION}"
resolve_system "${IMAGE}" "${VERSION}" || die "failed to resolve ${IMAGE}:${VERSION}"
CLIENT_VER="${RESOLVED_VER}"
CLIENT_REF="${RESOLVED_REF}"
log "Resolved cl-repository-client → ${CLIENT_VER} (${CLIENT_REF})"

rm -rf "${DEST}"
mkdir -p "${DEST}"
pull_extract "${CLIENT_REF}" "${DEST}"

CLIENT_DIR="$(find_client_dir "${DEST}")" \
  || die "cl-repository-client.asd not found after oras pull into ${DEST}"

if [[ "${PULL_DEPS}" == "true" || "${PULL_DEPS}" == "1" ]]; then
  QLFILE="${CLIENT_DIR}/qlfile"
  if [[ -f "${QLFILE}" ]]; then
    log "Pulling client bootstrap deps from OCI (${SYSTEMS_NS})"
    seeds=()
    while IFS= read -r s; do
      s="$(nocr "${s}")"
      [[ -n "${s}" ]] && seeds+=("${s}")
    done < <(qlfile_seeds "${QLFILE}")
    pull_system_tree "${DEST}" "${seeds[@]}"
  else
    log "No qlfile in extracted client; skipping dep pull"
  fi
fi

SOURCE_REGISTRY="${WORKSPACE}//:${DEST}//:"
if command -v cygpath >/dev/null 2>&1; then
  # SBCL/ASDF on Windows wants D:/…, not the MSYS /d/… mount used by tar.
  # ASDF splits CL_SOURCE_REGISTRY on ';' on Windows — ':' would split D: drives.
  CLIENT_DIR="$(cygpath -m "${CLIENT_DIR}")"
  DEST="$(cygpath -m "${DEST}")"
  WORKSPACE="$(cygpath -m "${WORKSPACE}")"
  SOURCE_REGISTRY="${WORKSPACE}//;${DEST}//;"
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    printf 'CL_REPOSITORY_CLIENT_DIR=%s\n' "${CLIENT_DIR}"
    printf 'CL_REPOSITORY_CLIENT_VERSION=%s\n' "${CLIENT_VER}"
    printf 'CL_REPOSITORY_DEST=%s\n' "${DEST}"
    printf 'CL_SOURCE_REGISTRY=%s\n' "${SOURCE_REGISTRY}"
  } >> "${GITHUB_ENV}"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'client-dir=%s\n' "${CLIENT_DIR}"
    printf 'client-version=%s\n' "${CLIENT_VER}"
    printf 'dest=%s\n' "${DEST}"
    printf 'source-registry=%s\n' "${SOURCE_REGISTRY}"
  } >> "${GITHUB_OUTPUT}"
fi

log "client-dir=${CLIENT_DIR}"
log "client-version=${CLIENT_VER}"
log "CL_SOURCE_REGISTRY=${SOURCE_REGISTRY}"
