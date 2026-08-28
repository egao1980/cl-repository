# 再利用 GHA: native OCI パッケージ公開 (JA)

原文: `docs/ci-native-publish.md`

## 概要

Caller が `native-<os>-<arch>` をビルド → reusable workflow が `lib/<os>-<arch>/` を整え、`ghcr.io/<owner>/cl-systems/<package>:<version>` へ公開。

## アーティファクト配置

| 配置 | `native-<os>-<arch>/` の中身 | 結果 |
|------|------------------------------|------|
| Flat | `libfoo.so` … | `lib/<os>-<arch>/` → role `native-library` |
| Nested | `lib/` + `grovel/` | `native-library` + `cffi-grovel-output` |

CFFI grovel 済み成果物を載せるパッケージ（event backends）は Nested。OpenSSL など純 native は Flat。

Caller skeleton / inputs / 契約の詳細は英文を参照。

（2026-08-14）`packager-tag` デフォルトは **0.16.0**。
（2026-08-27）`sbcl-dynamic-space-mb` デフォルトは **8192**（CUDA 級 overlay の gzip で apt SBCL 既定 ~1GB が OOM するため）。
（2026-08-28）`:skip-catalog t` は共有 `<namespace>/catalog` だけ省略。パッケージリポの `:latest` アンカーは書く。
