# Переиспользуемый GHA: публикация native OCI-пакетов (RU)

Исходный документ: `docs/ci-native-publish.md`

## Назначение

Caller собирает native-артефакты `native-<os>-<arch>` → reusable workflow раскладывает `lib/<os>-<arch>/`, грузит packager через `setup-lisp` + `cl-repo:ensure-systems` (как `publish-source.yml`; без QL / apt SBCL / raw `oras pull`) и публикует пакет в `ghcr.io/<owner>/cl-systems/<package>:<version>`. Бинарники — overlay, Lisp — обычный `ros -l`.

## Раскладки артефактов

| Раскладка | Содержимое `native-<os>-<arch>/` | Результат |
|-----------|----------------------------------|-----------|
| Flat | `libfoo.so` … | `lib/<os>-<arch>/` → роль `native-library` |
| Nested | `lib/` + `grovel/` | `native-library` + `cffi-grovel-output` |

Nested нужен пакетам с pre-groveled CFFI (event backends). Flat — путь OpenSSL / pure-native.

Полный caller skeleton, inputs и контракт — в английской версии.

(2026-08-14) Дефолт `packager-tag` — **0.16.0**.
(2026-08-28) Дефолт `packager-tag` — **latest** (`v0.18.0` — PIS-зависимости + якорь `:latest` при skip-catalog).
(2026-08-27) Дефолт `sbcl-dynamic-space-mb` — **8192** (gzip CUDA-размера overlay убивает ~1GB heap). `ros dynamic-space-size=`.
(2026-09-01) packager грузится через `setup-lisp` + `ensure-systems`. Пин `0.10.0` — старый QL-workaround.
(2026-08-28) `:skip-catalog t` пропускает только общий `<namespace>/catalog`. Якорь `:latest` на репозитории пакета всё равно пишется.
