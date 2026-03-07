(defpackage :cl-repository-client/tests/platform-resolver-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/platform-resolver
                #:detect-local-platform #:resolve-manifests #:universal-manifest-p)
  (:import-from :cl-oci/descriptor #:make-descriptor)
  (:import-from :cl-oci/digest #:parse-digest)
  (:import-from :cl-oci/platform #:make-platform)
  (:import-from :cl-oci/image-index #:make-image-index)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+))
(in-package :cl-repository-client/tests/platform-resolver-test)

(deftest detect-platform
  (multiple-value-bind (os arch impl) (detect-local-platform)
    (ok (stringp os) "OS detected")
    (ok (stringp arch) "Arch detected")
    (ok (stringp impl) "Implementation detected")))

(deftest resolve-universal-only
  (let* ((universal (make-descriptor :media-type +oci-image-manifest-v1+
                                     :digest (parse-digest "sha256:aaa")
                                     :size 100))
         (idx (make-image-index :manifests (list universal))))
    (multiple-value-bind (univ overlays) (resolve-manifests idx)
      (ok univ "Universal found")
      (ok (null overlays) "No overlays"))))

(deftest universal-manifest-detection
  (let ((with-plat (make-descriptor :media-type +oci-image-manifest-v1+
                                    :digest (parse-digest "sha256:bbb")
                                    :size 100
                                    :platform (make-platform :os "linux" :architecture "amd64")))
        (without-plat (make-descriptor :media-type +oci-image-manifest-v1+
                                       :digest (parse-digest "sha256:ccc")
                                       :size 100)))
    (ng (universal-manifest-p with-plat))
    (ok (universal-manifest-p without-plat))))
