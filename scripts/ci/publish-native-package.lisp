;;; Publish a cl-repository package with platform native-library overlays
;;; (and optional cffi-grovel-output when grovel/<os>-<arch>/ is present).
;;;
;;; Packager/oci-client are loaded via ensure-packager.lisp (setup-lisp +
;;; cl-repo:ensure-systems), same as canned `ci` phase:publish. Native
;;; binaries stay in artifact overlays — this file is ordinary Lisp.
;;;
;;; Env:
;;;   PKG_NAME         — ASDF system name (required)
;;;   PKG_SOURCE_DIR   — Lisp-only source tree (required)
;;;   LIB_ROOT         — directory containing <os>-<arch>/ native dirs
;;;   GROVEL_ROOT      — optional; sibling ../grovel of LIB_ROOT by default
;;;   PLATFORMS_FILE   — lines "os/arch"
;;;   OCI_REGISTRY REGISTRY_URL OCI_NAMESPACE
;;;   GITHUB_ACTOR GITHUB_TOKEN
;;;   SKIP_CATALOG     — "true" / "false" (default true)
;;;   PACKAGER_VERSION — optional OCI tag (empty / latest → client default)
;;; Optional overrides (empty = use .asd):
;;;   PKG_VERSION PKG_DESCRIPTION PKG_LICENSE
;;;   PKG_DEPENDS_ON PKG_PROVIDES PKG_CFFI_LIBS

(require :asdf)
(load (merge-pathnames "ensure-packager.lisp" *load-truename*))
(load (merge-pathnames "publish-native-package-impl.lisp" *load-truename*))
