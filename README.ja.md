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


**HTTP.** レジストリ通信は `http-protocol` 上の cl-stack 非同期バックエンド（`http-backend-async` × `event-backend-libuv`、TLS は `cl-stack-ssl`）を、そのスタックがロードできる場合に使用し、できない場合は `http-backend-dexador` を使います。`CL_REPO_HTTP_BACKEND=async|dexador|auto` で選択を強制できます。`setup-client` がネイティブオーバーレイをインストールできるようになるまで、CI イメージには dexador が残ります。

**依存関係の解決。** 解決は各パッケージの条件を満たす最新バージョンから始め、古いバージョンは競合が起きたパッケージについてだけ取得します。1 回の sync または install の間、タグ一覧・設定・マニフェスト・トークンのキャッシュを共有します。非同期バックエンドでは、レジストリへの問い合わせを 1 つのイベントループ上で最大 8 件同時に送ります（`CL_REPO_FETCH_JOBS`、1 なら 1 件ずつ）。パッケージの設定は実行をまたいで `$XDG_CACHE_HOME/cl-repository/configs/` に保存されます（`CL_REPO_CONFIG_CACHE=<ディレクトリ>` で場所を変更、`off` で無効化）。保存されたエントリは、そのタグへの HEAD が保存時と同じダイジェストを返したときだけ使われます。`CL_REPO_TRACE_HTTP=1` を設定すると、レジストリへの各リクエストを stderr に記録します。 lock にないパッケージは、インストール済みの最新版ではなく公開済みの最新版に解決します。インストール済みのコピーでも、クライアント自身のツリー（`~/.cl-repository-client`）にあるコピーでも、古ければ更新されます。最新版はプロジェクトが最初に探すインストールツリーに入り、lock にも記録されます。lock にあるパッケージはそのバージョンのままで、どのレジストリにも問い合わせられないときはインストール済みのバージョンを使います。公開済みのバージョンがすべて `(:version name min)` より古いときは `cl-repo: agent-tools 0.4.1 or later is required; the registry has 0.4.0 (published versions: 0.3.2, 0.4.0)`（コンディション `unsatisfied-dependencies`）で失敗し、古いバージョンのものは何もインストールしません。

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

普通の `.asd` で足ります。同じディレクトリの `qlfile` / `qlfile.lock` も、各エントリの依存関係とともに入ります。`qlfile` だけのディレクトリもプロジェクトです。
既定のレジストリは `https://ghcr.io` / `egao1980/cl-systems` です。
`cl-repo test` は同じ SBCL の新しいイメージでテストを実行し、そこにはソースレジストリだけを渡す。クライアント自身のシステム（dexador、cl+ssl とその OpenSSL）はロードされない。`CL_REPO_TEST_IN_PROCESS=1` でクライアントのイメージ内で実行する。
cl-repo が起動するイメージ（クライアント、テストイメージ、`cl-repo run` の Lisp）はすべて 1 つの fasl ルート `$XDG_CACHE_HOME/common-lisp/cl-repo/<impl>/` にコンパイルする。SBCL では、そこでのコンパイルは fasl ごとの排他ロック（fasl の隣の `<fasl>.lock`）を、ロードは共有ロックを持つので、並行実行が互いの fasl をロード中に消すことはない。
`cl-repo` コマンドは CI の `sbcl-dynamic-space-mb` と同じ 4096 MB のヒープで SBCL を起動する（macOS の SBCL の既定は 1 GB で、大きなテストスイートのコールドコンパイルで使い切ることがある）。テスト用イメージも同じサイズになる。`CL_REPO_DYNAMIC_SPACE_MB=<MB>` で別のサイズを指定し、空または `0` なら Roswell と SBCL に任せる。

`cl-repo sync`（したがって `test` と `run` も）はプロジェクトの依存閉包を `cl-repo.lock` に記録する。各パッケージのバージョン、index digest、レジストリで、プロジェクトのレジストリがその後ロードするバージョンそのもの。lock が最新である間（`.asd` や `qlfile` がそれより新しくなく、依存の走査が届くものをすべて lock している）、sync は lock からインストールする。解決もタグ一覧の取得もせず、ローカルにないバージョンだけを digest を確かめてから取得する。そうでなければ解決して lock を書き直す。`--locked` は lock が最新でないとき解決せずに失敗する。`--no-lock` は lock を読まず書かずに解決する。`cl-repo restore` は lock の全エントリを入れ直す。 レジストリも digest も持たないエントリ（ローカルだけのインストール）がインストールされていなければ lock は最新でなく、`--locked` はそこで失敗する。バージョンがタグでないエントリ（`:version` のないパッケージは `latest` としてインストールされる）は digest で取得する。

### CLI

```sh
cl-repo sync
cl-repo test
cl-repo run -- sbcl --script tool.lisp
cl-repo ros --system foo/tool -l tool.lisp -q
cl-repo publish
cl-repo add-overlay
cl-repo version --bump patch
cl-repo publish --overlay
cl-repo install alexandria
```


### Lisp の実行

`cl-repo run -- <command…>` は sync してからコマンドを実行する。Lisp（ros、sbcl、ccl、ecl、abcl）は source registry を設定済みの状態で起動し、`CL_SOURCE_REGISTRY` はエクスポートしない（source-registry の設定ファイルは読まない。渡された `CL_SOURCE_REGISTRY` の `:tree` / `:directory` は sync・test・run で同じく使う）。`cl-repo ros …` は `cl-repo run -- ros …` の短縮形（他の Lisp も同様）。先頭の `--system NAME` / `--overlay NAME` は cl-repo のオプションで、それ以降は `--help` や `ros run` も含めてそのまま Lisp に渡す。 `cl-repo ros` は Roswell を `+Q`（Quicklisp なし）で起動する。プロジェクトのレジストリにないシステムは Roswell の Quicklisp dist から読み込まれず、ロードに失敗する。引数に `-Q` を入れると Quicklisp が再び有効になる。

### バージョン

`cl-repo version` は `:version` を表示し、`cl-repo version 1.4.0` で設定、`cl-repo version --bump major|minor|patch|revision` で上げる（`revision` は上流リリースへの4番目: `3.5.9` → `3.5.9.1`）。`.asd` のバージョン文字列だけが変わる。`--system foo/bar` で別の `defsystem` を選ぶ。公開ワークフローは `cl-repo version "$V"` を使い、`sed` や同期スクリプトは不要。

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

3. **overlay を `.asd` に書き、そのあと公開する。** `add-overlay` はファイルだけを、しかもそのシステムの `:overlays` の値だけを編集する（コメント・`#+`・レイアウトはそのまま）。フラグなしはこのマシンの os と arch。`--os` / `--arch` / `--lisp` のどれかを渡すと、渡した部分だけがキーになる（値なしはそのマシン）。成果物は `lib/<key>/`、grovel は `grovel/<key>/`。

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

`ghcr.io` 上のプライベート依存は [プライベートパッケージ](#プライベートパッケージ) を参照してください。

`test-system.yml` / `publish-source.yml` の Ubuntu job は
`ghcr.io/egao1980/cl-repository/ci-base`（Roswell + SBCL + クライアント済み）で走ります。
これは `jobs.<id>.container` であり Docker コンテナアクションではありません。
macOS / Windows は job container 非対応なので VM 上でインストールします（キャッシュあり）。 クライアントのリリースごとにそのバージョンで再ビルドされ、`client-<version>` タグが付く（タグとローカルビルドは [docker/ci-base](docker/ci-base/README.md)）。

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

### プライベートパッケージ

`cl-repo` はレジストリのホストに対する認証情報が見つからない限り、匿名で pull します。最初に当てはまるソースが使われます。

| ソース | 送信先 | ユーザー名 |
|---|---|---|
| `CL_REPO_REGISTRY_TOKEN` | `CL_REPO_REGISTRY_HOST` のホスト（カンマ区切り、既定は `ghcr.io`） | `CL_REPO_REGISTRY_USERNAME`、既定は `x-access-token` |
| `GITHUB_TOKEN` と `GITHUB_ACTOR`（GitHub Actions が両方を設定） | `ghcr.io` のみ | `GITHUB_ACTOR` |
| Docker の `config.json`（`$DOCKER_CONFIG`、なければ `~/.docker`）の `auths`。`docker login` が書く形式 | そのエントリのホスト | エントリのもの |

空の変数は未設定として扱います。credential helper（`credsStore`、`credHelpers`）は読みません。代わりに `CL_REPO_REGISTRY_TOKEN` を使ってください。認証情報はレジストリのトークンエンドポイント（Basic 認証を求めるレジストリならレジストリ自身）にだけ送られ、他のホストには送られず、表示されることもありません。レジストリが拒否すると、`cl-repo` は変数名またはファイル名（値ではなく）を示すエラーで停止します。匿名 pull へのフォールバックはしません。フォールバックするとプライベートパッケージが「存在しない」と報告されるためです。匿名で pull するには変数を外してください。公開（publish）ではこの認証情報を使いません。

ローカルでは GitHub CLI を使います（トークンには `read:packages` が必要）。

```sh
CL_REPO_REGISTRY_TOKEN=$(gh auth token) cl-repo test
```

CI（`test-system.yml`、`test-system-impl.yml`、`ci` action）では job の `GITHUB_TOKEN`（`permissions: packages: read`）で `ghcr.io` から pull します。これは公開パッケージを読めます。プライベートパッケージは、そのパッケージが呼び出し元リポジトリにアクセスを許可した後に読めます。パッケージのページで **Package settings → Manage Actions access → Add repository** を開き、ロール *Read* を選びます。パッケージがアクセスを許可できない場合（別アカウントの所有など）は、`read:packages` を持つ personal access token をシークレットに保存し、`registry-token` として渡します。workflow はそれを `CL_REPO_REGISTRY_TOKEN` に設定し、`GITHUB_TOKEN` より先に使います。

```yaml
jobs:
  test:
    uses: egao1980/cl-repository/.github/workflows/test-system.yml@main
    secrets:
      registry-token: ${{ secrets.PACKAGES_READ_TOKEN }}
```

独自のステップでは `env:` に `CL_REPO_REGISTRY_TOKEN` を設定してください。

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
