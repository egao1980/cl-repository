(defpackage :cl-oci/tests/digest-test
  (:use :cl :rove)
  (:import-from :cl-oci/digest
                #:compute-digest #:parse-digest #:format-digest
                #:digest-algorithm #:digest-hex #:digest-equal #:verify-digest)
  (:import-from :cl-oci/conditions #:oci-digest-mismatch))
(in-package :cl-oci/tests/digest-test)

(deftest compute-digest-empty-data
  (let ((d (compute-digest (make-array 0 :element-type '(unsigned-byte 8)))))
    (ok (string= (digest-algorithm d) "sha256"))
    (ok (string= (digest-hex d) "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))))

(deftest compute-digest-string
  (let ((d (compute-digest "hello world")))
    (ok (string= (digest-algorithm d) "sha256"))
    (ok (string= (digest-hex d) "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"))))

(deftest parse-and-format-digest
  (let ((d (parse-digest "sha256:abcdef0123456789")))
    (ok (string= (digest-algorithm d) "sha256"))
    (ok (string= (digest-hex d) "abcdef0123456789"))
    (ok (string= (format-digest d) "sha256:abcdef0123456789"))))

(deftest digest-equality
  (let ((a (parse-digest "sha256:abc"))
        (b (parse-digest "sha256:abc"))
        (c (parse-digest "sha256:def")))
    (ok (digest-equal a b))
    (ng (digest-equal a c))))

(deftest verify-digest-success
  (let ((d (compute-digest "test")))
    (ok (verify-digest "test" d))))

(deftest verify-digest-failure
  (let ((d (parse-digest "sha256:0000000000000000000000000000000000000000000000000000000000000000")))
    (ok (signals (verify-digest "test" d) 'oci-digest-mismatch))))
