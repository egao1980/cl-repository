(defpackage :cl-oci/tests/serialization-test
  (:use :cl :rove)
  (:import-from :cl-oci/serialization #:to-json-string #:from-json-string #:from-json)
  (:import-from :cl-oci/manifest #:make-manifest #:manifest-schema-version #:manifest-layers)
  (:import-from :cl-oci/image-index #:make-image-index #:image-index-manifests)
  (:import-from :cl-oci/descriptor #:make-descriptor #:descriptor-media-type #:descriptor-size)
  (:import-from :cl-oci/digest #:parse-digest #:format-digest #:digest-algorithm)
  (:import-from :cl-oci/platform #:make-platform #:platform-os)
  (:import-from :cl-oci/config #:cl-system-config #:make-cl-system-config #:config-system-name #:config-depends-on)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+ #:+oci-image-config-v1+
                #:+oci-image-layer-tar-gzip+ #:+oci-image-index-v1+))
(in-package :cl-oci/tests/serialization-test)

(defun make-test-manifest ()
  (let ((config (make-descriptor :media-type +oci-image-config-v1+
                                 :digest (parse-digest "sha256:aaa111")
                                 :size 128))
        (layer (make-descriptor :media-type +oci-image-layer-tar-gzip+
                                :digest (parse-digest "sha256:bbb222")
                                :size 2048)))
    (make-manifest :config config :layers (list layer))))

(deftest manifest-round-trip
  (let* ((m (make-test-manifest))
         (json (to-json-string m))
         (m2 (from-json 'manifest json)))
    (ok (= (manifest-schema-version m2) 2))
    (ok (= (length (manifest-layers m2)) 1))
    (ok (= (descriptor-size (first (manifest-layers m2))) 2048))))

(deftest image-index-round-trip
  (let* ((desc (make-descriptor :media-type +oci-image-manifest-v1+
                                :digest (parse-digest "sha256:ccc333")
                                :size 512
                                :platform (make-platform :os "linux" :architecture "amd64")))
         (idx (make-image-index :manifests (list desc)))
         (json (to-json-string idx))
         (idx2 (from-json 'image-index json)))
    (ok (= (length (image-index-manifests idx2)) 1))
    (let ((d (first (image-index-manifests idx2))))
      (ok (string= (platform-os (cl-oci/descriptor:descriptor-platform d)) "linux")))))

(deftest cl-system-config-round-trip
  (let* ((cfg (make-cl-system-config :system-name "test-system"
                                     :version "1.0.0"
                                     :depends-on '("alexandria" "cffi")
                                     :provides '("test-system" "test-system/utils")))
         (json (to-json-string cfg))
         (cfg2 (from-json 'cl-system-config json)))
    (ok (string= (config-system-name cfg2) "test-system"))
    (ok (= (length (config-depends-on cfg2)) 2))))

(deftest versioned-deps-round-trip
  (let* ((cfg (make-cl-system-config :system-name "my-app"
                                     :version "2.0.0"
                                     :depends-on '("alexandria" ("babel" . "0.5") "cffi")))
         (json (to-json-string cfg))
         (cfg2 (from-json 'cl-system-config json))
         (deps (config-depends-on cfg2)))
    (ok (= (length deps) 3))
    (ok (stringp (first deps)))
    (ok (string= (first deps) "alexandria"))
    ;; Second dep should be a cons with version
    (ok (consp (second deps)))
    (ok (string= (car (second deps)) "babel"))
    (ok (string= (cdr (second deps)) "0.5"))
    (ok (stringp (third deps)))
    (ok (string= (third deps) "cffi"))))
