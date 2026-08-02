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
