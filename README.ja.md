# CL Repository

<img src="https://img.shields.io/badge/WARN-LLM%20GENERATED-FF6347"/>

Common Lisp パッケージ向けの OCI ベース配布システムです。

言語版:
- English: `README.md`
- Russian: `README.ru.md`
- Japanese: `README.ja.md`

パッケージは標準 OCI アーティファクトとして扱われ、任意の OCI 互換レジストリ（GHCR、Docker Hub、Quay など）へ push でき、任意の OCI クライアント（oras、crane、skopeo）または同梱の CL ネイティブクライアントで pull できます。

## なぜ CL Repository か

Quicklisp は Common Lisp ライブラリの導入には優れていますが、制約があります。月次更新の単一 curated snapshot 方式のため、同僚が 0.25 を使っている状況で `cffi` を 0.24.1 に固定するといった運用が難しく、再現可能ビルド用 lockfile もありません。さらに重要なのは、ネイティブ依存に対する標準的な仕組みがないことです。CFFI で C ライブラリをラップする場合、各利用者が groveler 実行のために適切な headers とコンパイラ toolchain をローカルに用意する必要があります。クリーンな CI マシンではこのセットアップコストがすぐに効いてきます。

`cl-repo` は別アプローチを取ります。各 CL システムを OCI アーティファクト（Docker イメージと同じフォーマット）としてパッケージ化します。任意の container registry（GHCR、Docker Hub、組織内 Harbor など）に push し、正確なバージョンタグで pull できます。すでにコンテナで使っている registry をそのまま Lisp package registry として使えるため、追加サーバー・追加アカウント・独自プロトコルは不要です。

最大の実利は **platform overlays** です。各パッケージは、特定の OS/arch（linux/amd64、darwin/arm64 など）向けに、事前ビルド済み `.so`/`.dylib`/`.dll` と pre-groveled CFFI 出力を含められます。これらは CI で一度だけビルドされ、ソースと一緒に配布されます。M1 Mac で `cl-repo install cffi` を実行すると、クライアントが適合 overlay を自動選択するため、インストール時に C コンパイラは不要です。CFFI grovel 出力は OS/アーキテクチャ依存で CL 実装依存ではないため、linux/amd64 の 1 つの overlay で SBCL、CCL、ECL を共通にカバーできます。pure-Lisp システムは overlay 不要で、universal source manifest だけでどこでも動作します。

qlot を使っている場合、`cl-repo` も「プロジェクト単位で依存を管理する」という思想は同じですが、輸送層を置き換えます。qlot が Quicklisp/Ultralisp の distribution から取得するのに対し、`cl-repo` は OCI registry から直接取得します。また [OCICL](https://github.com/ocicl/ocicl) と完全互換で、`cl-repo` パッケージは OCICL クライアントで使え、その逆も可能です。さらに標準 OCI アーティファクトなので、Lisp ツールなしでも `oras` / `crane` / `skopeo` で直接取得できます。

**要点:**

- 既存の任意 OCI registry に保存可能（GHCR、Docker Hub、ECR、Harbor、self-hosted）
- プロジェクト単位で厳密なバージョン固定（lockfile + digest pinning）による再現可能 CI
- Platform overlays: OS/arch ごとの prebuilt native libs + pre-groveled CFFI（インストール時に C コンパイラ不要）
- 1 プラットフォーム 1 overlay を全 CL 実装で共用
- 標準 OCI ツール対応（`oras` / `crane` / `skopeo`）
- OCICL 互換

## システム一覧

| System | Description |
|--------|-------------|
| `cl-oci` | OCI Image / Distribution 仕様を CLOS で表現するライブラリ |
| `cl-oci-client` | OCI Distribution Spec v1.1 HTTP クライアント |
| `cl-repository-packager` | CL システムを OCI アーティファクト化する ASDF プラグイン + build matrix |
| `cl-repository-client` | OCI registry からパッケージをインストールするクライアントライブラリ + CLI |
| `cl-repository-ql-exporter` | Quicklisp/Ultralisp から OCI へ一括エクスポート |

## クイックスタート

```sh
cl-repo sync
cl-repo test
cl-repo publish
```

普通の `.asd` で足ります。同じディレクトリの `qlfile` / `qlfile.lock` も入ります。
既定のレジストリは `https://ghcr.io` / `egao1980/cl-systems` です。

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

### 既存プロジェクトのオンボーディング

```sh
cl-repo sync
cl-repo test
```

### `.asd` に埋め込む OCI 設定

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

完全仕様は [docs/spec.md](docs/spec.md) を参照してください。

### 増分 platform overlays

Platform overlays は加算的です。先に pure-Lisp パッケージを公開し、後から platform-specific overlays を追加できます（例: 異なる OS/arch runner の CI job）。

#### ワークフロー

1. **ソースのみパッケージを公開**（universal manifest、overlay なし）:

```lisp
(defsystem "my-cffi-lib"
  :version "1.0.0"
  :depends-on ("cffi")
  :components (...))
```

```sh
cl-repo publish my-cffi-lib --registry ghcr.io --namespace my-org/my-project
```

2. **各対象プラットフォームでネイティブライブラリをビルド**（CI またはローカル）。

3. **overlay を `.asd` に書き、そのあと公開する。** `add-overlay` はファイルだけを編集する。フラグなしはこのマシンの os と arch。`--os` / `--arch` / `--lisp` のどれかを渡すと、渡した部分だけがキーになる（値なしはそのマシン）。成果物は `lib/<key>/`、grovel は `grovel/<key>/`。

```sh
cl-repo add-overlay --os linux --arch amd64
cl-repo add-overlay --lisp ecl
cl-repo publish
cl-repo publish --overlay
```

`publish` はソースマニフェストと、ファイルがある overlay をすべて push する。`publish --overlay` はソースを飛ばし、このマシンに一番具体的な overlay を push する。`publish --overlay cuda` はその名前の overlay。`sync` は名前のない一致 overlay を、汎用から具体へ積む。`cuda` のような名前は `cl-repo sync --overlay cuda` まで入らない。

#### コンシューマ CI（canned actions）

`ci-install.lisp` / `ci-test.lisp` / `publish-checkout.lisp` をコピーしないでください。パッケージと CI 追加分は `.asd`（`:depends-on` + `:properties (:cl-repo …)`）に置きます。足りないときだけ `scripts/ci/` フック。

```yaml
jobs:
  test:
    uses: egao1980/cl-repository/.github/workflows/test-system.yml@main
```

`test-system.yml` / `publish-source.yml` の Ubuntu job は
`ghcr.io/egao1980/cl-repository/ci-base`（Roswell + SBCL + クライアント済み）で走ります。
これは `jobs.<id>.container` であり Docker コンテナアクションではありません。
macOS / Windows は job container 非対応なので VM 上でインストールします（キャッシュあり）。

他の処理系（ECL / CCL / ABCL）は `test-system-impl.yml` を使います。同じ
install/test フェーズを VM 上で実行し、処理系は Roswell がインストール・キャッシュします。
ECL の既定は `26.5.5`（cl-stack-mobile のピン）です:

```yaml
jobs:
  test-ecl:
    uses: egao1980/cl-repository/.github/workflows/test-system-impl.yml@main
    with:
      lisp: ecl            # または ccl-bin / abcl-bin（CFFI 用 JNA 設定済み）
```

または:

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

ソースのみ公開: `publish-source.yml`。ネイティブ: `publish-native-package.yml`。詳細: [`.github/actions/ci`](.github/actions/ci/)。

`setup-lisp` はクライアントを runner に置き、`CL_SOURCE_REGISTRY` は export しない。素の VM では `setup-client` + `setup-roswell` を呼び、`~/.roswell` と `.cl-repository` をキャッシュする（クライアントのキーは解決済み semver。`:latest` エイリアスは使わない）。`setup-client` は `ghcr.io/egao1980/cl-repository/cl-repository-client:latest`（system-name **anchor**）→ アノテーションの semver → `oras pull` する。**Lisp クライアントの版としてこのリポジトリの git タグをピンしない。** `version` は OCI 成果物を凍結するときだけ渡す。クライアントが必要な **各 job** で `setup-lisp` を呼び、そのあと `cl-repo sync` と `cl-repo test` を実行する。

#### CI 例（GitHub Actions）

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

インストール時にはクライアントが適切な overlay を自動選択します。pure-Lisp システムは overlay を完全にスキップします。

### インストール

```sh
cl-repo install alexandria
cl-repo install cffi:0.24.1
```

アーティファクトは普通の OCI イメージです。`oras`、`crane`、`skopeo` で pull できます。ASDF へ入れるのは `cl-repo install` です。

### OCICL パッケージの読み込み

`cl-repo` は [OCICL](https://github.com/ocicl/ocicl) registry（`ghcr.io/ocicl/*`）からも pull できます。OCICL namespace を `:type :ocicl` で登録します:

```lisp
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
(cl-repo:load-system "alexandria")
```

`cl-repo` と OCICL の registry は混在可能で、クライアントは登録順に探索します:

```lisp
(cl-repo:add-registry "https://ghcr.io" :namespace "my-org/my-project")          ; cl-repo 形式（GitHub デフォルト）
(cl-repo:add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)          ; OCICL 形式
(cl-repo:load-system "alexandria")  ; まず cl-repo を試し、見つからなければ OCICL
```

OCICL との差異（empty config blobs、tarball prefix stripping、date-commit version tags）は自動処理されます。

`cl-repo` パッケージ自体も OCICL 互換です。source layer は `<name>-<version>/` root prefix と対応 title（`<name>-<version>.tar.gz`）を持つため、OCICL クライアントで直接利用できます。

### システム保護

稼働中の Lisp イメージ（例: Swank/SLIME や Slynk/SLY で接続中）で特定システムを更新すると、アクティブな接続が切断される可能性があります。`cl-repository-client` はデフォルトで有効な 2 つの保護メカニズムを提供します:

**1. プレフィックスベース保護** -- `*protected-system-prefixes*`（デフォルト: `("swank" "slynk")`）に一致するシステムは、対応パッケージがイメージ内に存在する場合スキップされます。メインシステムとすべてのサブシステム（例: `swank/sbcl`、`slynk/mrepl`）をカバーします。

**2. ロード済みシステムのスナップショット** -- `load-system` または `update` の初回使用時に、現在登録されている全 ASDF システムのスナップショットが取得されます。これらのシステムは更新・再インストールされません。`*protect-loaded-systems*`（デフォルト: `T`）で制御します。

```lisp
;; Programmatic API
(setf cl-repo:*protected-system-prefixes* '("swank" "slynk" "my-server"))
(setf cl-repo:*protect-loaded-systems* t)     ; デフォルト
(cl-repo:snapshot-loaded-systems)              ; 明示的スナップショット（通常は自動）
```

CLI: `--protect`（繰り返し指定可）でプレフィックスを追加:

```sh
cl-repo update --protect hunchentoot --protect my-app
cl-repo load alexandria --protect swank
```

`--force` ですべての保護を無効化し、強制更新できます。

## 例

| Example | Description |
|---------|-------------|
| [01-basic-usage](examples/01-basic-usage/) | REPL と CLI からシステムをロード |
| [02-publish-system](examples/02-publish-system/) | CL システムのビルドと公開 |
| [03-quicklisp-mirror](examples/03-quicklisp-mirror/) | Quicklisp を OCI にミラー |
| [04-native-deps](examples/04-native-deps/) | CFFI + platform overlays |
| [05-ci-workflow](examples/05-ci-workflow/) | GitHub Actions CI/CD |
| [06-asd-embedded-config](examples/06-asd-embedded-config/) | `.asd` 埋め込み OCI 設定 |
| [07-multiplatform-native-ci](examples/07-multiplatform-native-ci/) | 実 C ライブラリ + CFFI grovel + マルチプラットフォーム CI |
| [08-github-qlot-onboarding](examples/08-github-qlot-onboarding/) | GitHub / qlot プロジェクトを OCI へオンボード |

## 開発

[Roswell](https://github.com/roswell/roswell) と [qlot](https://github.com/fukamachi/qlot) が必要です。

```sh
qlot install
qlot exec ros run
```

または devcontainer（VS Code / Cursor + Roswell + Alive）を利用できます。

### テスト実行

ユニットテスト:

```sh
qlot exec ros -e '(asdf:test-system "cl-oci")'
qlot exec ros -e '(asdf:test-system "cl-oci-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-packager")'
qlot exec ros -e '(asdf:test-system "cl-repository-client")'
qlot exec ros -e '(asdf:test-system "cl-repository-ql-exporter")'
```

統合テスト（`localhost:5050` に Docker OCI registry が必要）:

```sh
docker run -d -p 5050:5000 --name oci-registry registry:2
qlot exec ros -e '(asdf:test-system "cl-repository-integration-tests")'
```

Docker + `act` を使った GitHub Actions ローカル検証:

```sh
act -W .github/workflows/test.yml -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

詳細チュートリアル: [docs/tutorial-local-testing-docker-act.md](docs/tutorial-local-testing-docker-act.md)。

## ライセンス

MIT
