(defpackage :cl-repository-client/tests/platform-resolver-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/platform-resolver
                #:detect-local-platform #:resolve-manifests #:universal-manifest-p)
  (:import-from :cl-oci/descriptor #:make-descriptor)
  (:import-from :cl-oci/digest #:parse-digest)
  (:import-from :cl-oci/platform #:make-platform)
  (:import-from :cl-oci/image-index #:make-image-index)
  (:import-from :cl-oci/annotations #:+cl-implementation+)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+))
(in-package :cl-repository-client/tests/platform-resolver-test)

(defun annotation-table (&rest pairs)
  (let ((table (make-hash-table :test 'equal)))
    (loop for (key value) on pairs by #'cddr
          do (setf (gethash key table) value))
    table))

(defun test-manifest (digest &key os arch implementation name)
  (let ((annotations (annotation-table)))
    (when implementation
      (setf (gethash +cl-implementation+ annotations) implementation))
    (when name
      (setf (gethash "dev.common-lisp.overlay.name" annotations) name))
    (make-descriptor :media-type +oci-image-manifest-v1+
                     :digest (parse-digest digest)
                     :size 100
                     :platform (when (or os arch)
                                 (make-platform :os os :architecture arch))
                     :annotations annotations)))

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
                                       :size 100))
        (lisp-only (make-descriptor :media-type +oci-image-manifest-v1+
                                    :digest (parse-digest "sha256:eclonly")
                                    :size 100
                                    :annotations (annotation-table +cl-implementation+ "ecl"))))
    (ng (universal-manifest-p with-plat))
    (ok (universal-manifest-p without-plat))
    (ng (universal-manifest-p lisp-only) "lisp-only overlay is not universal")))

(deftest resolve-overlay-stack-generic-first
  (let* ((universal (test-manifest "sha256:univ"))
         (linux (test-manifest "sha256:linux" :os "linux" :arch "amd64"))
         (ecl (test-manifest "sha256:ecl" :implementation "ecl"))
         (idx (make-image-index :manifests (list linux universal ecl))))
    (multiple-value-bind (univ overlays)
        (resolve-manifests idx :os "linux" :arch "amd64" :implementation "ecl")
      (ok (eq univ universal) "Universal separated from overlays")
      (ok (equal overlays (list ecl linux))
          "ecl (1 part) then linux/amd64 (2 parts)"))))

(deftest resolve-overlay-stack-by-implementation
  (let* ((universal (test-manifest "sha256:univ2"))
         (linux (test-manifest "sha256:linux2" :os "linux" :arch "amd64"))
         (ecl (test-manifest "sha256:ecl2" :implementation "ecl"))
         (sbcl (test-manifest "sha256:sbcl" :implementation "sbcl"))
         (both (test-manifest "sha256:both" :os "linux" :arch "amd64" :implementation "sbcl"))
         (idx (make-image-index :manifests (list both ecl universal sbcl linux))))
    (multiple-value-bind (univ overlays)
        (resolve-manifests idx :os "linux" :arch "amd64" :implementation "ecl")
      (ok (eq univ universal))
      (ok (equal overlays (list ecl linux))
          "sbcl overlays do not match ecl"))
    (multiple-value-bind (univ overlays)
        (resolve-manifests idx :os "linux" :arch "amd64" :implementation "sbcl")
      (ok (eq univ universal))
      (ok (equal overlays (list sbcl linux both))
          "sbcl-only, then linux/amd64, then linux/amd64+sbcl"))))

(deftest named-overlay-excluded
  (let* ((universal (test-manifest "sha256:univ3"))
         (linux (test-manifest "sha256:linux3" :os "linux" :arch "amd64"))
         (cuda (test-manifest "sha256:cuda" :os "linux" :arch "amd64" :name "cuda"))
         (idx (make-image-index :manifests (list universal cuda linux))))
    (multiple-value-bind (univ overlays)
        (resolve-manifests idx :os "linux" :arch "amd64" :implementation "ecl")
      (ok (eq univ universal))
      (ok (equal overlays (list linux)) "named cuda overlay is not automatic"))))

(deftest same-specificity-name-order
  (let* ((beta (test-manifest "sha256:beta" :os "linux" :arch "amd64" :name "beta"))
         (alpha (test-manifest "sha256:alpha" :os "linux" :arch "amd64" :name "alpha"))
         (later (test-manifest "sha256:later" :os "linux" :arch "amd64"))
         (earlier (test-manifest "sha256:earlier" :os "linux" :arch "amd64"))
         (idx (make-image-index :manifests (list beta later alpha earlier))))
    (multiple-value-bind (univ overlays)
        (resolve-manifests idx :os "linux" :arch "amd64" :implementation "ecl")
      (ok (null univ))
      (ok (equal overlays (list later earlier))
          "same specificity keeps both unnamed overlays in index order")
      (ng (member alpha overlays))
      (ng (member beta overlays)))))
