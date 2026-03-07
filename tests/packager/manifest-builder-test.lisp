(defpackage :cl-repository-packager/tests/manifest-builder-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/manifest-builder
                #:build-config-blob #:build-manifest-for-layers #:build-image-index
                #:built-manifest #:built-manifest-json #:built-manifest-digest
                #:built-manifest-size #:built-manifest-descriptor))
(in-package :cl-repository-packager/tests/manifest-builder-test)

(deftest build-config-blob-test
  (multiple-value-bind (octets digest size)
      (build-config-blob "test-system" :version "1.0" :depends-on '("dep-a"))
    (ok (plusp (length octets)))
    (ok (search "sha256:" digest))
    (ok (= size (length octets)))))

(deftest build-manifest-for-layers-test
  (multiple-value-bind (cfg-octets cfg-digest cfg-size)
      (build-config-blob "test-system" :version "1.0")
    (let ((bm (build-manifest-for-layers cfg-octets cfg-digest cfg-size nil)))
      (ok (stringp (built-manifest-json bm)))
      (ok (search "sha256:" (built-manifest-digest bm)))
      (ok (plusp (built-manifest-size bm))))))
