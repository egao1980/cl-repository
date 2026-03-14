# Локальное тестирование через Docker + act (RU)

Исходный документ: `docs/tutorial-local-testing-docker-act.md`

## Назначение

Запуск CI-пайплайнов GitHub Actions локально для проверки сборки, тестов и публикации.

## Базовый сценарий

1. Поднять локальный OCI registry (Docker).
2. Запустить job `test` через `act`.
3. Запустить job `integration` через `act`.

## Быстрый старт

```sh
docker rm -f oci-registry 2>/dev/null || true
docker run -d --name oci-registry -p 5050:5000 registry:2
act -W .github/workflows/test.yml -j test -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
act -W .github/workflows/test.yml -j integration -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

Полный пошаговый сценарий (включая локальную симуляцию publish/tag) см. в английской версии.
