(defpackage :crypto-wrapper
  (:use :cl :cffi)
  (:export #:crypto-version
           #:sha256-hex))
