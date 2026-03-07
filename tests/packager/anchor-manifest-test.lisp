(defpackage :cl-repository-packager/tests/anchor-manifest-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/manifest-builder
                #:build-anchor-manifest #:built-manifest #:built-manifest-json #:built-manifest-digest)
  (:import-from :cl-oci/media-types #:+cl-system-name-anchor-v1+ #:+cl-namespace-root-v1+)
  (:import-from :cl-oci/descriptor #:make-descriptor #:descriptor-digest)
  (:import-from :cl-oci/digest #:parse-digest))
(in-package :cl-repository-packager/tests/anchor-manifest-test)

(deftest test-anchor-manifest-basic
  (multiple-value-bind (bm config-octets config-digest)
      (build-anchor-manifest +cl-namespace-root-v1+)
    (ok (typep bm 'built-manifest))
    (ok (stringp (built-manifest-json bm)))
    (ok (stringp (built-manifest-digest bm)))
    (ok (typep config-octets '(vector (unsigned-byte 8))))
    (ok (stringp config-digest))
    ;; JSON should contain the artifact type
    (ok (search "namespace-root" (built-manifest-json bm)))))

(deftest test-anchor-manifest-with-annotations
  (let ((ann (make-hash-table :test 'equal)))
    (setf (gethash "test-key" ann) "test-value")
    (multiple-value-bind (bm config-octets config-digest)
        (build-anchor-manifest +cl-system-name-anchor-v1+
                               :annotations ann)
      (declare (ignore config-octets config-digest))
      (ok (search "test-key" (built-manifest-json bm)))
      (ok (search "test-value" (built-manifest-json bm))))))

(deftest test-anchor-manifest-with-subject
  (let ((subject (make-descriptor :media-type "application/vnd.oci.image.manifest.v1+json"
                                  :digest (parse-digest "sha256:abcdef1234567890")
                                  :size 0)))
    (multiple-value-bind (bm config-octets config-digest)
        (build-anchor-manifest +cl-system-name-anchor-v1+
                               :subject subject)
      (declare (ignore config-octets config-digest))
      ;; JSON should contain subject field
      (ok (search "subject" (built-manifest-json bm))))))

(deftest test-anchor-manifest-with-config-data
  (let ((data (babel:string-to-octets "{\"system-name\":\"test\"}" :encoding :utf-8)))
    (multiple-value-bind (bm config-octets config-digest)
        (build-anchor-manifest +cl-system-name-anchor-v1+
                               :config-data data)
      (declare (ignore config-digest))
      (ok (equalp config-octets data))
      ;; Config media type should be the CL system config type (not empty)
      (ok (search "common-lisp.system.config" (built-manifest-json bm))))))
