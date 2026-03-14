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

```lisp
;; 設定済み OCI registry からシステムをロード（ql:quickload 相当）
(asdf:load-system "cl-repository-client")
(cl-repo:add-registry "https://ghcr.io" :namespace "my-org/my-project")
(cl-repo:load-system "alexandria")

;; システムをパッケージ化して公開（.asd :properties の OCI 設定を読む）
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

### 既存プロジェクトのオンボーディング

まだ OCI registry に存在しないプロジェクトでも、Quicklisp dist へ先に追加せずに取り込めます。

```sh
# GitHub ソースから直接公開
cl-repo publish-github owner/repo --ref v1.2.3 \
  --registry ghcr.io --namespace my-org/my-project

# qlot メタデータから install/publish（qlfile/qlfile.lock は自動検出）
# - ql エントリは OCI registry からインストール
# - github/git エントリは --publish-sources で先に自動公開可能
cl-repo sync-qlot --publish-sources \
  --use-lock \
  --registry ghcr.io --namespace my-org/my-project

# 必要な場合のみパスを明示
cl-repo sync-qlot --use-lock \
  --qlfile /path/to/qlfile \
  --qlfile-lock /path/to/qlfile.lock \
  --registry ghcr.io --namespace my-org/my-project
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

3. **公開済みパッケージに overlay を追加**:

```sh
# linux/amd64 runner:
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 \
  --native-paths lib/linux-amd64/libfoo.so \
  --tag 1.0.0 \
  --registry ghcr.io --namespace my-org/my-project

# darwin/arm64 runner:
cl-repo add-overlay my-cffi-lib \
  --os darwin --arch arm64 \
  --native-paths lib/darwin-arm64/libfoo.dylib \
  --tag 1.0.0 \
  --registry ghcr.io --namespace my-org/my-project

# windows/amd64 runner:
cl-repo add-overlay my-cffi-lib \
  --os windows --arch amd64 \
  --native-paths lib/windows-amd64/foo.dll \
  --tag 1.0.0 \
  --registry ghcr.io --namespace my-org/my-project
```

`add-overlay` は毎回、既存 Image Index を pull し、新しい overlay blobs と manifest を push し、overlay descriptor を index に追加して同じ tag へ再 push します。OCI tag は mutable pointer なので、異なるプラットフォームターゲットに対して安全かつ冪等です。

複数ネイティブファイルを 1 overlay に含めることもできます（カンマ区切り）:

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 \
  --native-paths lib/libfoo.so,lib/libbar.so \
  --tag 1.0.0
```

ABI 依存の強い overlay（grovel 出力、特定 glibc/SDK でリンクした native libs）では `--os-version` で OS バージョンを固定してください。クライアントは `os-version` の厳密一致を優先し、なければ generic os/arch overlay にフォールバックします:

```sh
cl-repo add-overlay my-cffi-lib \
  --os linux --arch amd64 --os-version ubuntu-22.04 \
  --native-paths lib/linux-amd64-u2204/libfoo.so \
  --tag 1.0.0
```

特定 CL 実装向け overlay の場合は `--lisp` を指定:

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

#### CI 例（GitHub Actions）

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
      - run: make native  # .so/.dylib をビルド
      - run: |
          cl-repo add-overlay my-cffi-lib \
            --os ${{ matrix.os }} --arch ${{ matrix.arch }} \
            --native-paths ${{ matrix.lib }} \
            --tag 1.0.0 \
            --registry ghcr.io --namespace "${{ github.repository }}"
```

インストール時にはクライアントが適切な overlay を自動選択します。pure-Lisp システムは overlay を完全にスキップします。

### 標準 OCI クライアントの利用（`cl-repo` 不要）

パッケージは標準 OCI アーティファクトです。任意 OCI クライアントで pull し、展開ディレクトリを ASDF に渡せます。

```sh
# Pure-Lisp パッケージ（source のみ）
oras pull ghcr.io/my-org/my-project/cl-oci:0.2.0 -o /tmp/
mkdir -p ~/.local/share/cl-systems/
tar -xzf /tmp/cl-oci-0.2.0.tar.gz -C ~/.local/share/cl-systems/

# ネイティブ libs 付きパッケージ — 全 layer は同一 prefix を使うため順に展開
oras pull --platform linux/amd64 ghcr.io/my-org/my-project/my-cffi-lib:1.0.0
for f in *.tar.gz; do tar xzf "$f" -C ~/.local/share/cl-systems/; done
# -> ~/.local/share/cl-systems/my-cffi-lib-1.0.0/         (source)
# -> ~/.local/share/cl-systems/my-cffi-lib-1.0.0/native/  (platform libs)
```

`--platform` なしでは `oras` は universal manifest（source-only）を選びます。`--platform` 指定時は source + native libs を含む self-contained artifact を取得します。全 layer は OCICL 互換の `<name>-<version>/` prefix を共有するため、重ね展開がきれいに機能します。

その後 Lisp 側で:

```lisp
(asdf:initialize-source-registry
  '(:source-registry
    (:tree (:home ".local/share/cl-systems/"))
    :inherit-configuration))

(asdf:load-system "cl-oci")
```

または `CL_SOURCE_REGISTRY` 環境変数を設定:

```sh
export CL_SOURCE_REGISTRY="(:source-registry (:tree (:home \".local/share/cl-systems/\")) :inherit-configuration)"
sbcl --eval '(asdf:load-system "cl-oci")'
```

スクリプトで pull + extract + load を一括実行する例:

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

これは任意 OCI クライアント（`oras`、`crane`、`skopeo`）と、ASDF 対応の任意 CL 実装で動作します。

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
