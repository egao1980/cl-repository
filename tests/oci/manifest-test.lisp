(defpackage :cl-oci/tests/manifest-test
  (:use :cl :rove)
  (:import-from :cl-oci/manifest #:make-manifest #:manifest-schema-version
                #:manifest-media-type #:manifest-layers #:manifest-config)
  (:import-from :cl-oci/descriptor #:make-descriptor #:descriptor-media-type)
  (:import-from :cl-oci/digest #:parse-digest)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+ #:+oci-image-config-v1+
                #:+oci-image-layer-tar-gzip+))
(in-package :cl-oci/tests/manifest-test)

(deftest make-manifest-basic
  (let* ((config (make-descriptor :media-type +oci-image-config-v1+
                                  :digest (parse-digest "sha256:cfg111")
                                  :size 256))
         (layer (make-descriptor :media-type +oci-image-layer-tar-gzip+
                                 :digest (parse-digest "sha256:lyr222")
                                 :size 4096))
         (m (make-manifest :config config :layers (list layer))))
    (ok (= (manifest-schema-version m) 2))
    (ok (string= (manifest-media-type m) +oci-image-manifest-v1+))
    (ok (= (length (manifest-layers m)) 1))
    (ok (string= (descriptor-media-type (manifest-config m)) +oci-image-config-v1+))))
