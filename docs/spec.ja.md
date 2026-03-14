# CL Repository OCI 仕様（日本語）

元ドキュメント: `docs/spec.md`

## 要点

- Common Lisp システムは **OCI Image Index** として配布します。
- 先頭 manifest は universal（`platform` なし）、続いて platform overlays を配置します。
- `artifactType`: `application/vnd.common-lisp.system.v1`
- config blob media type:
  `application/vnd.common-lisp.system.config.v1+json`
- layer は標準 OCI layer media type を使用します。
- OCICL 互換のため、source layer は `<name>-<version>/` プレフィックスを持ちます。

## 構成

1. Image Index（トップレベル）
2. Universal manifest（ソース）
3. Overlay manifests（OS/arch/implementation 依存物）

## アノテーション

- 標準 OCI: `org.opencontainers.image.*`
- CL 拡張: `dev.common-lisp.*`

## 注意

厳密な仕様（media types、anchors/referrers、layer roles、JSON 例）は `docs/spec.md` を参照してください。
