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

```sh
cl-repo sync
cl-repo test
cl-repo publish
```

Обычного `.asd` достаточно. `qlfile` и `qlfile.lock` в том же каталоге ставятся вместе с ним.
Реестр по умолчанию — `https://ghcr.io` / `egao1980/cl-systems`.

### CLI

```sh
cl-repo sync
cl-repo test
cl-repo run -- sbcl --script tool.lisp
cl-repo publish
cl-repo add-overlay
cl-repo publish --overlay
cl-repo install alexandria
```

### Онбординг существующих проектов

```sh
cl-repo sync
cl-repo test
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

3. **Запишите overlay в `.asd`**, затем опубликуйте. `add-overlay` только правит файл. Вызов без флагов — os и arch этой машины. Любой из `--os`, `--arch`, `--lisp` оставляет только указанные части (флаг без значения — эта машина). Файлы кладите в `lib/<key>/`, grovel — в `grovel/<key>/`.

```sh
cl-repo add-overlay --os linux --arch amd64
cl-repo add-overlay --lisp ecl
cl-repo publish
cl-repo publish --overlay
```

`publish` пушит исходный манифест и каждый overlay, чьи файлы есть. `publish --overlay` пропускает исходники и пушит самое специфичное совпадение для этой машины. `publish --overlay cuda` пушит именованный overlay. `sync` ставит все подходящие безымянные overlay, от общего к частному. Имя вроде `cuda` не ставится, пока не вызван `cl-repo sync --overlay cuda`.

#### CI потребителя (canned actions)

Не копируйте `ci-install.lisp` / `ci-test.lisp` / `publish-checkout.lisp`. Метаданные пакета и CI — в `.asd` (`:depends-on` + `:properties (:cl-repo …)`). Хуки в `scripts/ci/` только если canned-пути недостаточно.

```yaml
jobs:
  test:
    uses: egao1980/cl-repository/.github/workflows/test-system.yml@main
```

Ubuntu-джобы в `test-system.yml` / `publish-source.yml` идут в
`ghcr.io/egao1980/cl-repository/ci-base` (Roswell + SBCL + клиент уже стоят).
Это `jobs.<id>.container`, не Docker container action.
macOS / Windows job container не поддерживают — ставят тулчейн на VM (с кэшем).

Другие реализации (ECL / CCL / ABCL) — через `test-system-impl.yml`: те же
фазы install/test на VM, реализацию ставит и кэширует Roswell. ECL по умолчанию
`26.5.5` (пин cl-stack-mobile):

```yaml
jobs:
  test-ecl:
    uses: egao1980/cl-repository/.github/workflows/test-system-impl.yml@main
    with:
      lisp: ecl            # или ccl-bin / abcl-bin (JNA для CFFI подключён)
```

Или по шагам:

```yaml
permissions:
  contents: read
  packages: read
container: ghcr.io/egao1980/cl-repository/ci-base:latest
defaults:
  run: { shell: bash }
steps:
  - uses: actions/checkout@v5
  - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
  - uses: egao1980/cl-repository/.github/actions/ci@main
    with: { phase: install }
  - uses: egao1980/cl-repository/.github/actions/ci@main
    with: { phase: test }
```

Source-only publish: `publish-source.yml`. Native: `publish-native-package.yml`. Подробности: [`.github/actions/ci`](.github/actions/ci/).

`setup-lisp` кладёт клиент на runner и не экспортирует `CL_SOURCE_REGISTRY`. На голой VM вызывает `setup-client` + `setup-roswell` и кэширует `~/.roswell` и `.cl-repository` (ключ клиента — резолвленный semver, не алиас `:latest`). `setup-client` резолвит `ghcr.io/egao1980/cl-repository/cl-repository-client:latest` (system-name **anchor**) → semver из аннотации → `oras pull`. **Не пиньте git-тег этого репозитория как версию Lisp-клиента** — `version` только чтобы заморозить OCI-артефакт. Вызывайте `setup-lisp` в **каждом job**, которому нужен клиент. Дальше job вызывает `cl-repo sync` и `cl-repo test`.

#### Пример CI (GitHub Actions)

```yaml
jobs:
  publish-source:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
      - run: cl-repo publish

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
      - uses: actions/checkout@v5
      - uses: egao1980/cl-repository/.github/actions/setup-lisp@main
      - run: make native
      - run: cl-repo add-overlay --os ${{ matrix.os }} --arch ${{ matrix.arch }}
      - run: cl-repo publish --overlay
```

Клиент автоматически выберет подходящий overlay при установке — pure-Lisp системы overlays полностью пропускают.

### Установка

```sh
cl-repo install alexandria
cl-repo install cffi:0.24.1
```

Артефакты — обычные OCI-образы. `oras`, `crane` и `skopeo` умеют их скачивать. В ASDF их ставит `cl-repo install`.

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

### Защита систем от обновления

При работе внутри живого Lisp-образа (например, подключённого через Swank/SLIME или Slynk/SLY) обновление определённых систем может разорвать активные соединения. `cl-repository-client` предоставляет два механизма защиты, включённых по умолчанию:

**1. Защита по префиксу** -- системы, совпадающие с `*protected-system-prefixes*` (по умолчанию: `("swank" "slynk")`), пропускаются, если соответствующий пакет присутствует в образе. Покрывает основную систему и все подсистемы (например, `swank/sbcl`, `slynk/mrepl`).

**2. Снапшот загруженных систем** -- при первом использовании `load-system` или `update` фиксируется снимок всех зарегистрированных ASDF-систем. Эти системы никогда не обновляются и не переустанавливаются. Управляется переменной `*protect-loaded-systems*` (по умолчанию: `T`).

```lisp
;; Programmatic API
(setf cl-repo:*protected-system-prefixes* '("swank" "slynk" "my-server"))
(setf cl-repo:*protect-loaded-systems* t)     ; по умолчанию
(cl-repo:snapshot-loaded-systems)              ; явный снапшот (обычно автоматический)
```

CLI: используйте `--protect` (повторяемая опция) для добавления дополнительных префиксов:

```sh
cl-repo update --protect hunchentoot --protect my-app
cl-repo load alexandria --protect swank
```

Используйте `--force` для обхода всей защиты и принудительного обновления.

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
