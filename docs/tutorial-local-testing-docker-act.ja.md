# Docker + act によるローカル検証（日本語）

元ドキュメント: `docs/tutorial-local-testing-docker-act.md`

## 目的

GitHub Actions ワークフローをローカルで実行し、ビルド/テスト/公開手順を事前検証します。

## 基本フロー

1. Docker でローカル OCI registry を起動
2. `act` で `test` ジョブ実行
3. `act` で `integration` ジョブ実行

## クイックスタート

```sh
docker rm -f oci-registry 2>/dev/null || true
docker run -d --name oci-registry -p 5050:5000 registry:2
act -W .github/workflows/test.yml -j test -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
act -W .github/workflows/test.yml -j integration -P ubuntu-latest=ghcr.io/catthehacker/ubuntu:act-latest
```

公開/tag シミュレーションを含む詳細は英語版を参照してください。
