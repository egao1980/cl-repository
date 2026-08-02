#!/usr/bin/env bash
# Arrange download-artifact output into lib/<os>-<arch>/ (+ optional grovel/)
# and platforms.txt.
#
# Expects: native-artifacts/native-<os>-<arch>/ from actions/download-artifact.
#
# Artifact layouts supported:
#   1. Flat (cl-stack-ssl): files directly under native-<os>-<arch>/
#      → lib/<os>-<arch>/
#   2. Nested (event backends): native-<os>-<arch>/{lib,grovel}/
#      → lib/<os>-<arch>/ and grovel/<os>-<arch>/
set -euo pipefail

ROOT="${1:-.}"
ART="${2:-native-artifacts}"
PLATFORMS_FILE="${3:-/tmp/platforms.txt}"

cd "$ROOT"
: > "$PLATFORMS_FILE"
mkdir -p lib
rm -rf grovel
# keep lib/ fresh for this arrange pass
find lib -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true

for dir in "$ART"/native-*; do
  [ -d "$dir" ] || continue
  slug=$(basename "$dir" | sed 's/^native-//')
  os=$(echo "$slug" | cut -d- -f1)
  arch=$(echo "$slug" | cut -d- -f2)
  target="lib/${os}-${arch}"
  mkdir -p "$target"

  if [ -d "$dir/lib" ] || [ -d "$dir/grovel" ]; then
    if [ -d "$dir/lib" ]; then
      cp -a "$dir/lib"/. "$target/"
    fi
    if [ -d "$dir/grovel" ]; then
      gdest="grovel/${os}-${arch}"
      mkdir -p "$gdest"
      cp -a "$dir/grovel"/. "$gdest/"
    fi
  else
    cp -a "$dir"/. "$target/"
  fi

  if [ -z "$(find "$target" -type f 2>/dev/null | head -1)" ]; then
    echo "error: no native files under ${target} (from ${dir})" >&2
    exit 1
  fi
  echo "${os}/${arch}" >> "$PLATFORMS_FILE"
done

if [ ! -s "$PLATFORMS_FILE" ]; then
  echo "error: no native-* artifacts under ${ART}" >&2
  exit 1
fi

echo "Platforms:"
cat "$PLATFORMS_FILE"
echo "Native files:"
find lib \( -type f -o -type l \) | head -80
if [ -d grovel ]; then
  echo "Grovel files:"
  find grovel -type f | head -40
fi
