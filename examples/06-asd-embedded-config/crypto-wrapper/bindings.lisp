(in-package :crypto-wrapper)

(define-foreign-library libcrypto-example
  (:darwin "libcrypto-example.dylib")
  (:unix "libcrypto-example.so")
  (t (:default "libcrypto-example")))

;; Not loaded at compile time -- requires the native lib to be present.
;; cl-repo:load-system handles extraction and CFFI path setup automatically.

(defcfun ("crypto_version" crypto-version) :string
  "Return version string of the native crypto library.")

(defcfun ("crypto_sha256_hex" sha256-hex) :string
  "Return hex-encoded SHA256 of DATA."
  (data :string)
  (len :int))
