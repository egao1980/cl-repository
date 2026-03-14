#!/usr/bin/env bash
set -euo pipefail

BASE_SHA=""

if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" && -n "${GITHUB_BASE_REF:-}" ]]; then
  git fetch --no-tags --prune --depth=1 origin "${GITHUB_BASE_REF}"
  BASE_SHA="$(git merge-base HEAD "origin/${GITHUB_BASE_REF}")"
elif git rev-parse --verify HEAD^ >/dev/null 2>&1; then
  BASE_SHA="$(git rev-parse HEAD^)"
else
  echo "No base commit available; skipping translation sync check."
  exit 0
fi

if [[ -z "${BASE_SHA}" ]]; then
  echo "Could not determine base commit; skipping translation sync check."
  exit 0
fi

changed_files=()
if [[ "${CI:-}" == "true" ]]; then
  while IFS= read -r line; do
    changed_files+=("${line}")
  done < <(git diff --name-only "${BASE_SHA}"...HEAD)
else
  while IFS= read -r line; do
    changed_files+=("${line}")
  done < <(git diff --name-only HEAD)
  while IFS= read -r line; do
    changed_files+=("${line}")
  done < <(git ls-files --others --exclude-standard)
fi

if [[ ${#changed_files[@]} -eq 0 ]]; then
  echo "No changed files; translation sync check passed."
  exit 0
fi

is_english_doc() {
  local path="$1"
  if [[ "${path}" == "README.md" ]]; then
    return 0
  fi
  if [[ "${path}" == docs/*.md && "${path}" != *.ru.md && "${path}" != *.ja.md ]]; then
    return 0
  fi
  return 1
}

contains_changed() {
  local needle="$1"
  for item in "${changed_files[@]}"; do
    if [[ "${item}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

english_docs=()
for file in "${changed_files[@]}"; do
  if is_english_doc "${file}"; then
    english_docs+=("${file}")
  fi
done

if [[ ${#english_docs[@]} -eq 0 ]]; then
  echo "No canonical English doc changes; translation sync check passed."
  exit 0
fi

missing_files=()
missing_updates=()

for en_doc in "${english_docs[@]}"; do
  ru_doc="${en_doc%.md}.ru.md"
  ja_doc="${en_doc%.md}.ja.md"

  if [[ ! -f "${ru_doc}" ]]; then
    missing_files+=("${ru_doc} (missing file for ${en_doc})")
  fi
  if [[ ! -f "${ja_doc}" ]]; then
    missing_files+=("${ja_doc} (missing file for ${en_doc})")
  fi

  if [[ -f "${ru_doc}" ]] && ! contains_changed "${ru_doc}"; then
    missing_updates+=("${ru_doc} (not updated with ${en_doc})")
  fi
  if [[ -f "${ja_doc}" ]] && ! contains_changed "${ja_doc}"; then
    missing_updates+=("${ja_doc} (not updated with ${en_doc})")
  fi
done

if [[ ${#missing_files[@]} -gt 0 || ${#missing_updates[@]} -gt 0 ]]; then
  echo "Documentation localization check failed."
  if [[ ${#missing_files[@]} -gt 0 ]]; then
    echo "Missing localized files:"
    printf '  - %s\n' "${missing_files[@]}"
  fi
  if [[ ${#missing_updates[@]} -gt 0 ]]; then
    echo "Localized files not updated in this change:"
    printf '  - %s\n' "${missing_updates[@]}"
  fi
  exit 1
fi

echo "Documentation localization check passed."
