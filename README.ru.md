# CL Repository

<img src="https://img.shields.io/badge/WARN-LLM%20GENERATED-FF6347"/>

OCI-ориентированная система дистрибуции пакетов Common Lisp.

Языковые версии:
- English: `README.md`
- Russian: `README.ru.md`
- Japanese: `README.ja.md`

Пакеты — это стандартные OCI-артефакты, которые можно публиковать в любой OCI-совместимый registry (GHCR, Docker Hub, Quay и т. д.) и извлекать любым OCI-клиентом (oras, crane, skopeo) или встроенным CL-клиентом.

## Почему CL Repository?

Quicklisp отлично подходит для старта с библиотеками Common Lisp, но у него есть ограничения. Он предоставляет единый курируемый срез, который обновляется раз в месяц — невозможно зафиксировать `cffi` на 0.24.1, пока у коллеги 0.25, и нет lockfile для воспроизводимых сборок. Ещё важнее то, что нет встроенной истории для нативных зависимостей. Если библиотека оборачивает C-библиотеку через CFFI, каждому пользователю нужны корректные headers и toolchain компилятора, чтобы запустить groveler локально. На «чистой» CI-машине эта стоимость настройки быстро растёт.

`cl-repo` идёт другим путём: каждая CL-система упаковывается как OCI-артефакт — тот же формат, что и Docker-образы. Вы публикуете пакет в любой container registry (GHCR, Docker Hub, Harbor в вашей организации) и получаете обратно по точным тегам версий. Registry, который уже используется для контейнеров, одновременно становится вашим Lisp package registry. Никаких дополнительных серверов, новых аккаунтов или собственного протокола.

Ключевая практическая выгода — **platform overlays**. Каждый пакет может включать предсобранные `.so`/`.dylib`/`.dll` и pre-groveled CFFI output для конкретных сочетаний OS/arch (linux/amd64, darwin/arm64 и т. д.). Они собираются один раз в CI и распространяются вместе с исходниками. Когда кто-то выполняет `cl-repo install cffi` на Mac M1, клиент автоматически выбирает подходящий overlay — компилятор C при установке не нужен. Так как CFFI grovel output зависит от OS и архитектуры, но не от реализации CL, одного linux/amd64 overlay достаточно для SBCL, CCL и ECL. Для pure-Lisp систем overlays не нужны вообще — везде работает универсальный source manifest.

Если вы знакомы с qlot, `cl-repo` разделяет ту же проектно-ориентированную философию зависимостей, но заменяет транспортный слой. Там, где qlot тянет из Quicklisp и Ultralisp, `cl-repo` тянет напрямую из OCI registry. Также есть полная совместимость с [OCICL](https://github.com/ocicl/ocicl): пакеты `cl-repo` работают в клиенте OCICL и наоборот. А поскольку это стандартные OCI-артефакты, их всегда можно получить через `oras`, `crane` или `skopeo` вообще без Lisp-инструментов.

**Коротко:**

- Храните пакеты в любом OCI registry, который уже используете (GHCR, Docker Hub, ECR, Harbor, self-hosted)
- Фиксируйте точные версии на проект, с lockfile и digest pinning для воспроизводимого CI
- Platform overlays: предсобранные нативные библиотеки + pre-groveled CFFI под OS/arch — без C-компилятора при установке
- Grovel один раз, используйте везде: один overlay на платформу обслуживает все CL-реализации
- Стандартные OCI-инструменты: pull через `oras`, `crane`, `skopeo` — Lisp не обязателен
- Совместимость с OCICL

## Системы

| Система | Описание |
|--------|----------|
| `cl-oci` | CLOS-библиотека, моделирующая спецификации OCI Image и Distribution |
| `cl-oci-client` | HTTP-клиент OCI Distribution Spec v1.1 |
| `cl-repository-packager` | ASDF-плагин + build matrix для упаковки CL-систем как OCI-артефактов |
| `cl-repository-client` | Клиентская библиотека + CLI для установки пакетов из OCI registry |
| `cl-repository-ql-exporter` | Массовый экспорт из Quicklisp/Ultralisp в OCI-артефакты |

## Быстрый старт

```lisp
;; Загрузка системы из настроенных OCI registry (аналог ql:quickload)
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "my-org/my-project")
(cl-repo:load-system "alexandria")

;; Упаковка и публикация системы (читает OCI-конфиг из .asd :properties)
(asdf:load-system "cl-repository-packager")
(asdf:operate 'cl-repository-packager:package-op "my-system")
```

### CLI

```sh
cl-repo install alexandria
cl-repo install cffi:0.24.1
cl-repo publish
cl-repo publish-github fukamachi/sxql --ref main --registry ghcr.io --namespace my-org/my-project
cl-repo sync-qlot --qlfile ./qlfile --registry ghcr.io --namespace my-org/my-project
cl-repo ql-export https://beta.quicklisp.org/dist/quicklisp.txt --registry ghcr.io --namespace my-org/my-project
```

### Онбординг существующих проектов

Вы можете заводить проекты, которых ещё нет в вашем OCI registry, без предварительного добавления в Quicklisp dist.

```sh
# Публикация напрямую из GitHub-исходников.
cl-repo publish-github owner/repo --ref v1.2.3 \
  --registry ghcr.io --namespace my-org/my-project

# Установка/публикация из метаданных qlot (авто-поиск qlfile/qlfile.lock).
# - ql-записи устанавливаются из OCI registry.
# - github/git-записи можно сначала авто-публиковать через --publish-sources.
cl-repo sync-qlot --publish-sources \
  --use-lock \
  --registry ghcr.io --namespace my-org/my-project

# Переопределяйте пути только при необходимости.
cl-repo sync-qlot --use-lock \
  --qlfile /path/to/qlfile \
  --qlfile-lock /path/to/qlfile.lock \
  --registry ghcr.io --namespace my-org/my-project
```

### Встроенный OCI-конфиг в `.asd`

```lisp
(defsystem "my-lib"
  :version "1.0.0"
  :depends-on ("cffi")
  :properties (:cl-repo (:cffi-libraries ("libfoo")
                          :overlays ((:platform (:os "linux" :arch "amd64")
                                      :layers ((:role "native-library"
                                                :files (("lib/libfoo.so" . "libfoo.so"))))))))
  :components (...))
```

Полная спецификация: [docs/spec.md](docs/spec.md).

### Инкрементальные platform overlays

Platform overlays аддитивны. Можно сначала опубликовать pure-Lisp пакет, а затем добавить platform-specific overlays (например, из CI job на разных OS/arch runner).

#### Workflow

1. **Опубликуйте пакет только с исходниками** (universal manifest, без overlays):

```lisp
(defsystem "my-cffi-lib"
  :version "1.0.0"
  :depends-on ("cffi")
  :components (...))
```

```sh
cl-repo publish my-cffi-lib --registry ghcr.io --namespace my-org/my-project
```

2. **Соберите нативные библиотеки** на каждой целевой платформе (в CI или локально).

3. **Добавьте overlays** к уже опубликованному пакету:

```sh
# На linux/amd64 runner:
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 \
  --native-paths lib/linux-amd64/libfoo.so \
  --tag 1.0.0 \
  --registry ghcr.io --namespace my-org/my-project

# На darwin/arm64 runner:
cl-repo add-overlay my-cffi-lib \
  --os darwin --arch arm64 \
  --native-paths lib/darwin-arm64/libfoo.dylib \
  --tag 1.0.0 \
  --registry ghcr.io --namespace my-org/my-project

# На windows/amd64 runner:
cl-repo add-overlay my-cffi-lib \
  --os windows --arch amd64 \
  --native-paths lib/windows-amd64/foo.dll \
  --tag 1.0.0 \
  --registry ghcr.io --namespace my-org/my-project
```

Каждый вызов `add-overlay` вытягивает текущий Image Index, публикует новые overlay blobs и manifest, дописывает descriptor overlay в index и повторно публикует обновлённый index под тем же тегом. OCI-теги — это изменяемые указатели, поэтому для различных platform target это безопасно и идемпотентно.

Можно включать несколько нативных файлов в один overlay (через запятую):

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 \
  --native-paths lib/libfoo.so,lib/libbar.so \
  --tag 1.0.0
```

Для ABI-чувствительных overlays (grovel output, native libs, собранные под конкретный glibc/SDK) фиксируйте версию ОС через `--os-version`. Клиент предпочитает точные совпадения `os-version` и откатывается на generic os/arch overlays:

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 --os-version ubuntu-22.04 \
  --native-paths lib/linux-amd64-u2204/libfoo.so \
  --tag 1.0.0
```

Если overlay нацелен на конкретную реализацию CL, передайте `--lisp`:

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 --lisp sbcl \
  --native-paths lib/linux-amd64/libfoo.so \
  --tag 1.0.0
```

#### Programmatic API

```lisp
(let* ((overlay (parse-overlay-spec
                  '(:platform (:os "linux" :arch "amd64")
                    :layers ((:role "native-library"
                              :files (("lib/libfoo.so" . "libfoo.so")))))))
       (result (build-overlay "my-cffi-lib" overlay :version "1.0.0")))
  (publish-overlay "https://ghcr.io" "my-org/my-project" "my-cffi-lib" "1.0.0" result))
```

#### Пример CI (GitHub Actions)

```yaml
jobs:
  publish-source:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: cl-repo publish my-cffi-lib --registry ghcr.io --namespace "${{ github.repository }}"

  add-overlay:
    needs: publish-source
    strategy:
      matrix:
        include:
          - os: linux
            arch: amd64
            runner: ubuntu-latest
            lib: lib/linux-amd64/libfoo.so
          - os: darwin
            arch: arm64
            runner: macos-14
            lib: lib/darwin-arm64/libfoo.dylib
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - run: make native  # build the .so/.dylib
      - run: |
          cl-repo add-overlay my-cffi-lib \
            --os ${{ matrix.os }} --arch ${{ matrix.arch }} \
            --native-paths ${{ matrix.lib }} \
            --tag 1.0.0 \
            --registry ghcr.io --namespace "${{ github.repository }}"
```

Клиент автоматически выберет подходящий overlay при установке — pure-Lisp системы overlays полностью пропускают.

### Использование стандартного OCI-клиента (без `cl-repo`)

Пакеты — стандартные OCI-артефакты: их можно получить любым OCI-клиентом, а затем указать ASDF на распакованный каталог.

```sh
# Pure-Lisp пакет (только исходники)
oras pull ghcr.io/my-org/my-project/cl-oci:0.2.0 -o /tmp/
mkdir -p ~/.local/share/cl-systems/
tar -xzf /tmp/cl-oci-0.2.0.tar.gz -C ~/.local/share/cl-systems/

# Пакет с нативными библиотеками — все слои используют один и тот же префикс, распаковывайте по порядку
oras pull --platform linux/amd64 ghcr.io/my-org/my-project/my-cffi-lib:1.0.0
for f in *.tar.gz; do tar xzf "$f" -C ~/.local/share/cl-systems/; done
# -> ~/.local/share/cl-systems/my-cffi-lib-1.0.0/         (source)
# -> ~/.local/share/cl-systems/my-cffi-lib-1.0.0/native/  (platform libs)
```

Без `--platform` `oras` выберет universal manifest (только исходники, любая платформа). С `--platform` вы получите self-contained артефакт, включающий source + native libs. Все слои разделяют OCICL-совместимый префикс `<name>-<version>/`, поэтому корректно накладываются друг на друга.

Дальше в Lisp:

```lisp
(asdf:initialize-source-registry
  '(:source-registry
    (:tree (:home ".local/share/cl-systems/"))
    :inherit-configuration))

(asdf:load-system "cl-oci")
```

Или задайте переменную окружения `CL_SOURCE_REGISTRY`:

```sh
export CL_SOURCE_REGISTRY="(:source-registry (:tree (:home \".local/share/cl-systems/\")) :inherit-configuration)"
sbcl --eval '(asdf:load-system "cl-oci")'
```

Для скриптов: pull + extract + load одним шагом:

```sh
#!/bin/sh
REGISTRY=ghcr.io/my-org/my-project
SYSTEM=cl-oci
TAG=0.2.0
DEST=~/.local/share/cl-systems

mkdir -p "${DEST}"
oras pull "${REGISTRY}/${SYSTEM}:${TAG}" -o /tmp/
tar -xzf "/tmp/${SYSTEM}-${TAG}.tar.gz" -C "${DEST}/"

sbcl --eval "(asdf:initialize-source-registry
               '(:source-registry
                 (:tree (:home \".local/share/cl-systems/\"))
                 :inherit-configuration))" \
     --eval "(asdf:load-system \"${SYSTEM}\")" \
     --eval "(format t \"~a loaded OK~%\" \"${SYSTEM}\")"
```

Это работает с любым OCI-клиентом (`oras`, `crane`, `skopeo`) и любой CL-реализацией с ASDF.

### Загрузка пакетов OCICL

`cl-repo` умеет тянуть пакеты из [OCICL](https://github.com/ocicl/ocicl) registry (`ghcr.io/ocicl/*`). Зарегистрируйте namespace OCICL с `:type :ocicl`:

```lisp
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
(cl-repo:load-system "alexandria")
```

Можно смешивать `cl-repo` и OCICL registry — клиент ищет по порядку:

```lisp
(cl-repo:add-registry "https://ghcr.io" :namespace "my-org/my-project")          ; формат cl-repo (дефолт для GitHub)
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)          ; формат OCICL
(cl-repo:load-system "alexandria")  ; сначала cl-repo, затем fallback на OCICL
```

Различия OCICL обрабатываются автоматически: empty config blobs, stripping tarball prefix, date-commit version tags.

Пакеты `cl-repo` также OCICL-совместимы — source layer использует корневой префикс `<name>-<version>/` и соответствующий layer title (`<name>-<version>.tar.gz`), поэтому клиент OCICL может потреблять пакеты `cl-repo` напрямую.

## Примеры

| Пример | Описание |
|---------|----------|
| [01-basic-usage](examples/01-basic-usage/) | Загрузка систем из REPL и CLI |
| [02-publish-system](examples/02-publish-system/) | Сборка и публикация CL-системы |
| [03-quicklisp-mirror](examples/03-quicklisp-mirror/) | Зеркалирование Quicklisp в OCI |
| [04-native-deps](examples/04-native-deps/) | CFFI + platform overlays |
| [05-ci-workflow](examples/05-ci-workflow/) | CI/CD на GitHub Actions |
| [06-asd-embedded-config](examples/06-asd-embedded-config/) | OCI-конфиг, встроенный в `.asd` |
| [07-multiplatform-native-ci](examples/07-multiplatform-native-ci/) | Реальная C-библиотека + CFFI grovel + мультиплатформенный CI |
| [08-github-qlot-onboarding](examples/08-github-qlot-onboarding/) | Онбординг GitHub и qlot проектов в OCI |

## Разработка

Нужны [Roswell](https://github.com/roswell/roswell) и [qlot](https://github.com/fukamachi/qlot).

```sh
qlot install
qlot exec ros run
```

Также можно использовать devcontainer (VS Code / Cursor с Roswell + Alive).

### Запуск тестов

Unit-тесты:

```sh
qlot exec ros -e '(asdf:test-system "cl-oci")'
qlot exec ros -e '(asdf:test-system "cl-oci-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-packager")'
qlot exec ros -e '(asdf:test-system "cl-repository-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-ql-exporter")'
```

Integration-тесты (нужен Docker OCI registry на `localhost:5050`):

```sh
docker run -d -p 5050:5000 --name oci-registry registry:2
qlot exec ros -e '(asdf:test-system "cl-repository-integration-tests")'
```

Локальное тестирование GitHub Actions через Docker + `act`:

```sh
act -W .github/workflows/test.yml -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

Полный туториал: [docs/tutorial-local-testing-docker-act.md](docs/tutorial-local-testing-docker-act.md).

## Лицензия

MIT
