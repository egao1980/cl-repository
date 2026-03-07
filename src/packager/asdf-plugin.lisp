(defpackage :cl-repository-packager/asdf-plugin
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec #:parse-overlay-spec #:build-package #:build-result)
  (:export #:package-op
           #:auto-package-spec
           #:discover-provided-systems
           #:normalize-dep))
(in-package :cl-repository-packager/asdf-plugin)

(defclass package-op (asdf:operation) ()
  (:documentation "ASDF operation to package a system as an OCI artifact."))

(defun normalize-dep (dep)
  "Normalize an ASDF dependency spec, preserving version constraints.
   Plain deps -> string. (:version \"name\" \"ver\") -> (\"name\" . \"ver\")."
  (etypecase dep
    (string (string-downcase dep))
    (symbol (string-downcase (symbol-name dep)))
    (cons (if (and (eq (first dep) :version) (>= (length dep) 3))
              (cons (string-downcase (string (second dep))) (string (third dep)))
              (string-downcase (string (second dep)))))))

(defun system-cl-repo-properties (system)
  "Extract :cl-repo value from SYSTEM's :properties.
   Handles both plist (:cl-repo (...)) and alist ((:cl-repo . (...))) formats."
  (let ((props (slot-value system (find-symbol (string '#:properties)
                                               (find-package :asdf/component)))))
    (etypecase (first props)
      (keyword (getf props :cl-repo))
      (cons (cdr (assoc :cl-repo props :test #'eq)))
      (null nil))))

(defun discover-provided-systems (source-dir)
  "Scan SOURCE-DIR for top-level *.asd files and extract system names from defsystem forms.
   Returns a deduplicated list of system name strings."
  (let ((names nil)
        (*read-eval* nil)
        (*package* (find-package :cl-user)))
    (dolist (asd-path (directory (merge-pathnames "*.asd" source-dir)))
      (handler-case
          (with-open-file (s asd-path :direction :input :if-does-not-exist nil)
            (when s
              (loop for form = (read s nil :eof)
                    until (eq form :eof)
                    when (and (listp form)
                              (symbolp (first form))
                              (string-equal "DEFSYSTEM" (symbol-name (first form)))
                              (second form))
                      do (let ((name (etypecase (second form)
                                       (string (second form))
                                       (symbol (string-downcase (symbol-name (second form)))))))
                           (pushnew name names :test #'string=)))))
        (error () nil)))
    (nreverse names)))

(defun auto-package-spec (system-name)
  "Auto-generate a package-spec by introspecting a loaded ASDF system.
   Reads OCI packaging metadata from the system's :properties under :cl-repo.

   Provides resolution order:
     1. Explicit :cl-repo :provides from .asd :properties
     2. Auto-discovered from *.asd files in source-dir
     3. Fallback: (list system-name)"
  (let* ((system (asdf:find-system system-name))
         (cl-repo (system-cl-repo-properties system))
         (source-dir (asdf:system-source-directory system))
         (provides (or (getf cl-repo :provides)
                       (when source-dir (discover-provided-systems source-dir))
                       (list (asdf:component-name system)))))
    (make-instance 'package-spec
                   :name (asdf:component-name system)
                   :version (asdf:component-version system)
                   :source-dir source-dir
                   :license (asdf:system-licence system)
                   :description (asdf:system-description system)
                   :author (asdf:system-author system)
                   :depends-on (mapcar #'normalize-dep (asdf:system-depends-on system))
                   :provides provides
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
