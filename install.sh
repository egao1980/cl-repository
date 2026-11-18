#!/usr/bin/env bash
# Install the cl-repo CLI for one user: the OCI-published cl-repository client
# in ~/.cl-repository-client and a `cl-repo` command in ~/.local/bin.
#
#   curl -fsSL https://raw.githubusercontent.com/egao1980/cl-repository/main/install.sh | bash
#
# Needs Roswell (`ros`, with SBCL), `oras` and python3. Re-run to upgrade: the
# client directory is replaced, so packages it installed are fetched again.
#
# Env: CL_REPOSITORY_DEST (client dir), CL_REPO_BIN_DIR (where `cl-repo` goes),
#      CL_REPOSITORY_CLIENT_VERSION (OCI tag, default latest),
#      CL_REPOSITORY_REF (git ref of setup-client.sh when piped, default main).
set -euo pipefail

DEST="${CL_REPOSITORY_DEST:-$HOME/.cl-repository-client}"
BIN_DIR="${CL_REPO_BIN_DIR:-$HOME/.local/bin}"
REF="${CL_REPOSITORY_REF:-main}"

die() { echo "install.sh: $*" >&2; exit 1; }

command -v ros >/dev/null 2>&1 || die "Roswell not found: https://roswell.github.io/ (then: ros install sbcl-bin)"
command -v oras >/dev/null 2>&1 || die "oras not found: https://oras.land/docs/installation (brew install oras)"
command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1 || die "python3 not found"
[[ "$DEST" = /* ]] || die "CL_REPOSITORY_DEST must be absolute: $DEST"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

here=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
setup="$here/.github/actions/setup-client/setup-client.sh"
if [[ -z "$here" || ! -f "$setup" ]]; then
  setup="$work/setup-client.sh"
  curl -fsSL "https://raw.githubusercontent.com/egao1980/cl-repository/${REF}/.github/actions/setup-client/setup-client.sh" \
    -o "$setup" || die "could not download setup-client.sh (ref ${REF})"
fi

echo "Installing the cl-repository client into $DEST"
(cd "$work" && CL_REPOSITORY_DEST="$DEST" bash "$setup")

mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/cl-repo" <<'WRAPPER'
#!/bin/sh
# cl-repo CLI over the client installed by cl-repository's install.sh.
# Finds the newest installed client (cl-oci-<version>), so an upgrade needs no
# edit here.
dest="${CL_REPOSITORY_DEST:-$HOME/.cl-repository-client}"
client="$(ls -d "$dest"/cl-oci-*/ 2>/dev/null | sort -V | tail -1)"
if [ -z "$client" ] || [ ! -f "${client}roswell/cl-repo.ros" ]; then
  echo "cl-repo: no client under $dest (run cl-repository's install.sh)" >&2
  exit 1
fi
CL_REPOSITORY_CLIENT_DIR="${CL_REPOSITORY_CLIENT_DIR:-$client}" \
CL_REPOSITORY_DEST="$dest" \
  exec ros +Q -- "${client}roswell/cl-repo.ros" "$@"
WRAPPER
chmod +x "$BIN_DIR/cl-repo"

echo "Installed $BIN_DIR/cl-repo"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "Add $BIN_DIR to PATH, e.g.: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
