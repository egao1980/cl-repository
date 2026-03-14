# CL Repository (Русская версия)

Исходная английская версия: `README.md`

OCI-ориентированная система дистрибуции пакетов Common Lisp.

## Что это

- Пакеты публикуются как стандартные OCI-артефакты.
- Можно использовать любые OCI-реестры: GHCR, Docker Hub, Quay, приватные registry.
- Поддерживаются platform overlays для нативных библиотек и CFFI-артефактов.
- Совместимо с OCICL.

## Быстрый старт (CLI)

```sh
cl-repo install alexandria
cl-repo publish
cl-repo publish-github owner/repo --registry ghcr.io --namespace my-org/my-project
cl-repo sync-qlot --use-lock --publish-sources --registry ghcr.io --namespace my-org/my-project
cl-repo ql-export https://beta.quicklisp.org/dist/quicklisp.txt --registry ghcr.io --namespace my-org/my-project
```

## Онбординг проектов

- Локальный проект: `cl-repo publish` (или `--all-systems`).
- GitHub: `cl-repo publish-github owner/repo`.
- qlot: `cl-repo sync-qlot` (авто-поиск `qlfile`/`qlfile.lock` вверх по дереву).
- Для зависимостей:
  - `--publish-dependencies` — публиковать отсутствующие локальные зависимости.
  - `--publish-ql-dependencies` — fallback через Quicklisp/Ultralisp exporter.
  - `--deps-dist-url` — URL dist (Quicklisp/Ultralisp).

## Документация

- Спецификация формата: `docs/spec.md`
- Требования: `docs/requirements/overview.md`
- Локальный CI (Docker + act): `docs/tutorial-local-testing-docker-act.md`

## Локализованные документы

Для основных документов есть пары:
- `*.ru.md` — русская версия
- `*.ja.md` — японская версия

При изменении английских документов обновляйте локализованные варианты в том же PR.
