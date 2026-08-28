# Переиспользуемый GHA: публикация native OCI-пакетов (RU)

Исходный документ: `docs/ci-native-publish.md`

## Назначение

Caller собирает native-артефакты `native-<os>-<arch>` → reusable workflow раскладывает `lib/<os>-<arch>/`, публикует пакет в `ghcr.io/<owner>/cl-systems/<package>:<version>`.

## Раскладки артефактов

| Раскладка | Содержимое `native-<os>-<arch>/` | Результат |
|-----------|----------------------------------|-----------|
| Flat | `libfoo.so` … | `lib/<os>-<arch>/` → роль `native-library` |
| Nested | `lib/` + `grovel/` | `native-library` + `cffi-grovel-output` |

Nested нужен пакетам с pre-groveled CFFI (event backends). Flat — путь OpenSSL / pure-native.

Полный caller skeleton, inputs и контракт — в английской версии.

(2026-08-14) Дефолт `packager-tag` — **0.16.0**.
(2026-08-27) Дефолт `sbcl-dynamic-space-mb` — **8192** (gzip CUDA-размера overlay убивает apt SBCL с ~1GB heap).
(2026-08-28) `:skip-catalog t` пропускает только общий `<namespace>/catalog`. Якорь `:latest` на репозитории пакета всё равно пишется.
