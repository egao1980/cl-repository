(defpackage :cl-repository-packager/asdf-plugin
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec #:parse-overlay-spec #:build-package #:build-result)
  (:export #:package-op
           #:auto-package-spec))
(in-package :cl-repository-packager/asdf-plugin)

(defclass package-op (asdf:operation) ()
  (:documentation "ASDF operation to package a system as an OCI artifact."))

(defun normalize-dep-name (dep)
  (string-downcase
   (etypecase dep
     (string dep)
     (symbol (symbol-name dep))
     (cons (string (second dep))))))

(defun system-cl-repo-properties (system)
  "Extract :cl-repo value from SYSTEM's :properties.
   Handles both plist (:cl-repo (...)) and alist ((:cl-repo . (...))) formats."
  (let ((props (slot-value system (find-symbol (string '#:properties)
                                               (find-package :asdf/component)))))
    (etypecase (first props)
      (keyword (getf props :cl-repo))
      (cons (cdr (assoc :cl-repo props :test #'eq)))
      (null nil))))

(defun auto-package-spec (system-name)
  "Auto-generate a package-spec by introspecting a loaded ASDF system.
   Reads OCI packaging metadata from the system's :properties under :cl-repo.

   In a .asd file:
     :properties (:cl-repo (:cffi-libraries (\"libfoo\")
                            :provides (\"my-system\" \"my-system/utils\")
                            :overlays ((:platform (:os \"linux\" :arch \"amd64\")
                                        :native-paths (\"lib/libfoo.so\")))))

   Supported :cl-repo keys:
     :cffi-libraries   - list of CFFI library names
     :provides         - list of provided system names (defaults to system name)
     :overlays         - list of overlay plists (see parse-overlay-spec)"
  (let* ((system (asdf:find-system system-name))
         (cl-repo (system-cl-repo-properties system)))
    (make-instance 'package-spec
                   :name (asdf:component-name system)
                   :version (asdf:component-version system)
                   :source-dir (asdf:system-source-directory system)
                   :license (asdf:system-licence system)
                   :description (asdf:system-description system)
                   :author (asdf:system-author system)
                   :depends-on (mapcar #'normalize-dep-name (asdf:system-depends-on system))
                   :provides (or (getf cl-repo :provides)
                                 (list (asdf:component-name system)))
                   :cffi-libraries (getf cl-repo :cffi-libraries)
                   :overlays (mapcar #'parse-overlay-spec
                                     (getf cl-repo :overlays)))))

(defmethod asdf:perform ((op package-op) (system asdf:system))
  (let* ((spec (auto-package-spec (asdf:component-name system)))
         (result (build-package spec)))
    (msg "~&Package built: ~a~%  Index digest: ~a~%  Blobs: ~d~%  Manifests: ~d~%"
            (asdf:component-name system)
            (cl-repository-packager/build-matrix:build-result-index-digest result)
            (length (cl-repository-packager/build-matrix:build-result-blobs result))
            (length (cl-repository-packager/build-matrix:build-result-manifests result)))
    result))
