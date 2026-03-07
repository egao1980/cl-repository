(defpackage :cl-oci/tests/descriptor-test
  (:use :cl :rove)
  (:import-from :cl-oci/descriptor
                #:make-descriptor #:descriptor-media-type #:descriptor-size
                #:descriptor-annotation)
  (:import-from :cl-oci/digest #:parse-digest)
  (:import-from :cl-oci/platform #:make-platform #:platform-os))
(in-package :cl-oci/tests/descriptor-test)

(deftest make-descriptor-basic
  (let ((d (make-descriptor :media-type "application/vnd.oci.image.layer.v1.tar+gzip"
                            :digest (parse-digest "sha256:abc123")
                            :size 1024)))
    (ok (string= (descriptor-media-type d) "application/vnd.oci.image.layer.v1.tar+gzip"))
    (ok (= (descriptor-size d) 1024))))

(deftest descriptor-with-platform
  (let ((d (make-descriptor :media-type "application/vnd.oci.image.manifest.v1+json"
                            :digest (parse-digest "sha256:def456")
                            :size 512
                            :platform (make-platform :os "linux" :architecture "amd64"))))
    (ok (string= (platform-os (cl-oci/descriptor:descriptor-platform d)) "linux"))))

(deftest descriptor-annotations
  (let ((d (make-descriptor :media-type "test" :digest (parse-digest "sha256:aaa") :size 0)))
    (setf (descriptor-annotation d "foo") "bar")
    (ok (string= (descriptor-annotation d "foo") "bar"))
    (ok (null (descriptor-annotation d "missing")))))
