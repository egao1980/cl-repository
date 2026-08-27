# Спецификация OCI-формата CL Repository (RU)

Исходный документ: `docs/spec.md`

## Кратко

- Пакет Common Lisp публикуется как **OCI Image Index**.
- Первый manifest — универсальный (без `platform`), далее идут platform overlays.
- `artifactType`: `application/vnd.common-lisp.system.v1`.
- Media type config-блоба:
  `application/vnd.common-lisp.system.config.v1+json`.
- Слои используют стандартный OCI layer media type.
- Для совместимости с OCICL source layer использует префикс `<name>-<version>/`.

## Структура

1. Image Index (верхний уровень)
2. Universal manifest (исходники)
3. Overlay manifests (os/arch/implementation-зависимые артефакты)

## Аннотации

- Стандартные OCI: `org.opencontainers.image.*`
- CL-специфичные: `dev.common-lisp.*`

## Нативные зависимости (cffi-libraries)

В config-блобе `cffi-libraries` сопоставляет каждой нативной библиотеке метаданные: `define-foreign-library`, `canary` и `search-path`. При установке `search-path` добавляется в `cffi:*foreign-library-directories*` (через `cl-repo-init.lisp`), чтобы `define-foreign-library` находил поставляемую библиотеку. В `.asd` запись допускается как имя-строка, так и `(имя . plist)`.

## CI потребителя (`:ci`)

`:properties (:cl-repo (:ci …))` в `.asd` — доп. поля для canned GH Action (`ci` / `test-system.yml`). `auto-package-spec` их игнорирует. Не копируйте `ci-install.lisp` по репозиториям.

## Slash-имена (`foo/bar`)

ASDF-вторичные системы (`ai-agent-protocol/mcp`) не могут быть отдельным GHCR-репозиторием. Они остаются в tar первичного пакета и в аннотации `provides`. Клиент мапит `foo/bar` → пакет `foo` (`oci-package-name`; `+` → `-plus-`, как `setup-client.sh`). Отдельные OCI-репозитории — только для имён без `/` (`cffi-toolchain`).

## Важно

Полные нормативные требования (media types, anchors/referrers, layer roles, примеры JSON) см. в `docs/spec.md`.
