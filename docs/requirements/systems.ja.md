# サブシステム要件（日本語）

元ドキュメント: `docs/requirements/systems.md`

## サブシステム

- `cl-oci`: OCI データモデル（descriptor/manifest/index/config/serialization）
- `cl-oci-client`: OCI Distribution Spec HTTP クライアント
- `cl-repository-packager`: CL システムを OCI へパッケージング
- `cl-repository-client`: インストール/解決/CLI
- `cl-repository-ql-exporter`: Quicklisp/Ultralisp から OCI へエクスポート

## 設計方針

サブシステムは疎結合で再利用可能に保つ:
- transport と format を分離
- packaging と install/runtime を分離
- exporter はエコシステム移行用 bootstrap として扱う

各モジュールの詳細要件は英語版を参照してください。
