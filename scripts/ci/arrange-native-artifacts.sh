#!/usr/bin/env bash
# Arrange download-artifact output into lib/<os>-<arch>/ + platforms.txt
# Expects: native-artifacts/native-<os>-<arch>/ from actions/download-artifact
set -euo pipefail

ROOT="${1:-.}"
ART="${2:-native-artifacts}"
PLATFORMS_FILE="${3:-/tmp/platforms.txt}"

cd "$ROOT"
: > "$PLATFORMS_FILE"
mkdir -p lib

for dir in "$ART"/native-*; do
  [ -d "$dir" ] || continue
  slug=$(basename "$dir" | sed 's/^native-//')
  os=$(echo "$slug" | cut -d- -f1)
  arch=$(echo "$slug" | cut -d- -f2)
  target="lib/${os}-${arch}"
  mkdir -p "$target"
  cp -a "$dir"/. "$target/"
  echo "${os}/${arch}" >> "$PLATFORMS_FILE"
done

if [ ! -s "$PLATFORMS_FILE" ]; then
  echo "error: no native-* artifacts under ${ART}" >&2
  exit 1
fi

echo "Platforms:"
cat "$PLATFORMS_FILE"
find lib \( -type f -o -type l \) | head -80
