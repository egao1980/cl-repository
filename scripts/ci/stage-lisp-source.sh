#!/usr/bin/env bash
# Copy selected paths from REPO_ROOT into STAGING (Lisp-only source tree).
# SOURCE_PATHS: newline- or comma-separated relative paths (files or dirs).
set -euo pipefail

REPO_ROOT="${1:?repo root}"
STAGING="${2:?staging dir}"
SOURCE_PATHS="${3:?source paths}"

rm -rf "$STAGING"
mkdir -p "$STAGING"

# Normalize separators to newlines
paths=$(printf '%s\n' "$SOURCE_PATHS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)
if [ -z "$paths" ]; then
  echo "error: empty SOURCE_PATHS" >&2
  exit 1
fi

cd "$REPO_ROOT"
while IFS= read -r p; do
  [ -e "$p" ] || { echo "error: missing source path: $p" >&2; exit 1; }
  if [ -d "$p" ]; then
    mkdir -p "$STAGING/$p"
    cp -a "$p"/. "$STAGING/$p/"
  else
    mkdir -p "$STAGING/$(dirname "$p")"
    cp -a "$p" "$STAGING/$p"
  fi
done <<< "$paths"

echo "Staged into $STAGING:"
find "$STAGING" -type f | head -80
