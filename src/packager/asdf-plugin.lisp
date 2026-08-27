(defpackage :cl-repository-packager/asdf-plugin
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec #:parse-overlay-spec #:build-package #:build-result)
  (:export #:package-op
           #:auto-package-spec
           #:discover-provided-systems
           #:normalize-dep
           #:test-system-name-p
           #:filter-publish-provides))
(in-package :cl-repository-packager/asdf-plugin)

(defclass package-op (asdf:operation) ()
  (:documentation "ASDF operation to package a system as an OCI artifact."))

(defun normalize-dep (dep)
  "Normalize an ASDF dependency spec, preserving version constraints.
   Plain deps -> string. (:version \"name\" \"ver\") -> (\"name\" . \"ver\").
   (:feature EXPR DEP) -> normalize DEP (feature expression ignored for metadata).
   (:require MOD) -> NIL (dropped by callers that remove NIL)."
  (etypecase dep
    (string (string-downcase dep))
    (symbol (string-downcase (symbol-name dep)))
    (cons
     (case (first dep)
       (:version
        (cons (string-downcase (string (second dep))) (string (third dep))))
       (:feature
        ;; (:feature <expr> <dep>) — expr may be a list, e.g. (:or :win32 …)
        (normalize-dep (third dep)))
       (:require
        nil)
       (t
        (string-downcase (string (second dep))))))))

(defun system-cl-repo-properties (system)
  "Extract :cl-repo value from SYSTEM's :properties.
   Handles both plist (:cl-repo (...)) and alist ((:cl-repo . (...))) formats."
  (let ((props (slot-value system (find-symbol (string '#:properties)
                                               (find-package :asdf/component)))))
    (etypecase (first props)
      (keyword (getf props :cl-repo))
      (cons (cdr (assoc :cl-repo props :test #'eq)))
      (null nil))))

(defun test-system-name-p (name)
  "True for ASDF names that look like test systems (not primary OCI packages)."
  (let* ((n (string-downcase name))
         (len (length n)))
    (flet ((suffixp (suffix)
             (let ((slen (length suffix)))
               (and (>= len slen)
                    (string= n suffix :start1 (- len slen))))))
      (or (search "/tests" n)
          (search "/test" n)
          (suffixp "-test")
          (suffixp "-tests")))))

(defun filter-publish-provides (system-name provides)
  "Provides written into the published package. Drops test systems.
   Slash secondaries stay in the list (they live in the primary tarball)."
  (let* ((primary (string-downcase (string system-name)))
         (raw (or provides (list primary)))
         (cleaned (remove-if #'test-system-name-p
                             (mapcar (lambda (s) (string-downcase (string s))) raw))))
    (if (member primary cleaned :test #'string=)
        cleaned
        (cons primary cleaned))))

(defun normalize-metadata-string (value)
  "Coerce ASDF metadata (author/description) to a single-line string or NIL.
   Lists (common for :author) become comma-separated; required because OCI
   annotation values must be strings (GHCR rejects JSON arrays → MANIFEST_INVALID)."
  (cond
    ((null value) nil)
    ((stringp value)
     (let ((s (string-trim '(#\Space #\Tab #\Newline #\Return) value)))
       (when (plusp (length s))
         (with-output-to-string (out)
           (loop for c across s
                 do (write-char (if (member c '(#\Newline #\Return #\Tab)) #\Space c)
                                out))))))
    ((and (consp value) (every #'stringp value))
     (normalize-metadata-string (format nil "~{~a~^, ~}" value)))
    (t (normalize-metadata-string (princ-to-string value)))))

(defun discover-provided-systems (source-dir)
  "Scan SOURCE-DIR for top-level *.asd files and extract system names from defsystem forms.
   Returns a deduplicated list of system name strings (test systems omitted)."
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
                           (unless (test-system-name-p name)
                             (pushnew name names :test #'string=))))))
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
                   :description (normalize-metadata-string (asdf:system-description system))
                   ;; ASDF :author may be a list (esrap) — OCI annotations require strings.
                   :author (normalize-metadata-string (asdf:system-author system))
                   :depends-on (remove nil (mapcar #'normalize-dep (asdf:system-depends-on system)))
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
