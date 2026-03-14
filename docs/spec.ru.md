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

## Важно

Полные нормативные требования (media types, anchors/referrers, layer roles, примеры JSON) см. в `docs/spec.md`.
