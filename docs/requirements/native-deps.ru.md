# Требования к нативным зависимостям (RU)

Исходный документ: `docs/requirements/native-deps.md`

## Цель

Нативные зависимости (C/C++ библиотеки, CFFI/groveler артефакты) должны поставляться как OCI overlays, чтобы установка была воспроизводимой и не требовала локальной сборки на каждой машине.

## Основные требования

- Разделение universal source и platform overlays.
- Явная привязка к платформе (`os`, `arch`, опционально `os-version`, `implementation`).
- Возможность ship prebuilt shared libraries и pre-groveled output.
- Корректная интеграция в runtime через init/loader логику.

## Практика

Подробные сценарии упаковки и публикации см. в английской версии и примерах `examples/04-native-deps` и `examples/07-multiplatform-native-ci`.
