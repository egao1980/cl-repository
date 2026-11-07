(defpackage :cl-repository-packager/asdf-plugin
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:import-from :cl-repository-packager/build-matrix
                #:package-spec #:parse-overlay-spec #:build-package #:build-result)
  (:export #:package-op
           #:auto-package-spec
           #:discover-provided-systems
           #:normalize-dep
           #:collect-external-depends-on
           #:test-system-name-p
           #:filter-publish-provides
           #:native-library-components
           #:check-native-libraries
           #:native-overlay-files
           #:derived-native-overlays))
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

(defun same-source-tree-p (system root-dir)
  (let ((d (ignore-errors (asdf:system-source-directory system))))
    (and d root-dir
         (or (uiop:pathname-equal d root-dir)
             (uiop:subpathp d root-dir)))))

(defun collect-external-depends-on (system)
  "Walk SYSTEM and same-tree children (package-inferred). Return external deps.
   Drops in-tree names (rove/main) so OCI annotations list real packages (dissect)."
  (let* ((root (asdf:system-source-directory system))
         (seen (make-hash-table :test #'equal))
         (external '()))
    (labels ((walk (sys)
               (let ((n (string-downcase (asdf:component-name sys))))
                 (unless (gethash n seen)
                   (setf (gethash n seen) t)
                   (dolist (raw (asdf:system-depends-on sys))
                     (let* ((dep (normalize-dep raw))
                            (name (if (consp dep) (car dep) dep)))
                       (when name
                         (let ((child (asdf:find-system name nil)))
                           (if (and child (same-source-tree-p child root))
                               (walk child)
                               (pushnew dep external :test #'equal))))))))))
      (walk system)
      (nreverse external))))

;;; Native overlays by convention: a platform's overlay is every file in its
;;; directory, lib/<os>-<arch>/ by default, shipped into native/ (what the CI
;;; native publish already does with artifact directories). Nothing to declare:
;;; platforms are the lib/<os>-<arch>/ directories present. Optional keys:
;;;   :native-platforms ("linux-amd64" ("darwin-arm64" . "out/mac/"))  ; strict list
;;;   :native-directory "build/{pair}/"                                 ; template
;;; A system with asdf-native (:native-library ...) components is checked: each
;;; platform must hold every non-optional library. asdf-native is reached via
;;; FIND-SYMBOL; the packaged system loaded it, the packager doesn't need it.

(defparameter +native-oses+ '("linux" "darwin" "windows" "freebsd"))

(defun %asdf-native (name)
  (let ((pkg (find-package "ASDF-NATIVE")))
    (and pkg (find-symbol name pkg))))

(defun native-library-components (system)
  "SYSTEM's asdf-native :NATIVE-LIBRARY components in load order (modules included)."
  (let ((class (let ((sym (%asdf-native "NATIVE-LIBRARY"))) (and sym (find-class sym nil)))))
    (when class
      (labels ((walk (c)
                 (loop for child in (asdf:component-children c)
                       if (typep child class) collect child
                       else if (typep child 'asdf:parent-component) append (walk child))))
        (walk system)))))

(defun %split-pair (pair)
  (let ((dash (position #\- pair)))
    (unless (and dash (member (subseq pair 0 dash) +native-oses+ :test #'string=))
      (error "Native platform ~S is not <os>-<arch> with os in ~{~A~^, ~}" pair +native-oses+))
    (values (subseq pair 0 dash) (subseq pair (1+ dash)))))

(defun %fill-pair (template pair)
  (multiple-value-bind (os arch) (%split-pair pair)
    (dolist (sub `(("{pair}" . ,pair) ("{os}" . ,os) ("{arch}" . ,arch)) template)
      (loop for at = (search (car sub) template)
            while at
            do (setf template (concatenate 'string (subseq template 0 at) (cdr sub)
                                           (subseq template (+ at (length (car sub))))))))))

(defun check-native-libraries (system pair files)
  "Signal an error unless FILES (file names) hold a variant of every
non-optional :NATIVE-LIBRARY component of SYSTEM for PAIR."
  (let ((names (%asdf-native "NATIVE-LIBRARY-NAMES"))
        (optional-p (%asdf-native "NATIVE-LIBRARY-OPTIONAL-P"))
        (os (intern (string-upcase (%split-pair pair)) :keyword)))
    (dolist (c (native-library-components system))
      (let ((wanted (funcall names c :os (if (member os '(:darwin :linux :windows)) os :unix))))
        (unless (or (some (lambda (w) (member w files :test #'string=)) wanted)
                    (and optional-p (funcall optional-p c)))
          (error "~A: ~A has no ~A (one of ~{~A~^, ~}); found ~{~A~^, ~}"
                 (asdf:component-name system) pair (asdf:component-name c) wanted files))))))

(defun native-overlay-files (system pair dir)
  "Files of DIR (non-recursive) as (absolute . file-name) pairs, checked
against SYSTEM's :NATIVE-LIBRARY components for PAIR."
  (let* ((files (uiop:directory-files (uiop:ensure-directory-pathname dir)))
         (pairs (loop for abs in files collect (cons (namestring abs) (file-namestring abs)))))
    (unless pairs (error "~A: no files under ~A for ~A" (asdf:component-name system) dir pair))
    (check-native-libraries system pair (mapcar #'cdr pairs))
    pairs))

(defun native-platform-directories (cl-repo source-dir)
  "→ list of (pair . directory) from :NATIVE-PLATFORMS, or discovered lib/<os>-<arch>/."
  (let ((declared (getf cl-repo :native-platforms))
        (template (getf cl-repo :native-directory)))
    (if declared
        (loop for entry in declared
              for pair = (if (consp entry) (car entry) entry)
              for dir = (merge-pathnames
                         (uiop:ensure-directory-pathname
                          (if (consp entry) (cdr entry) (%fill-pair (or template "lib/{pair}/") pair)))
                         source-dir)
              do (unless (uiop:directory-exists-p dir)
                   (error ":native-platforms lists ~A but ~A does not exist" pair (namestring dir)))
              collect (cons pair dir))
        (unless template
          (loop for dir in (uiop:subdirectories (merge-pathnames "lib/" source-dir))
                for name = (car (last (pathname-directory dir)))
                when (ignore-errors (%split-pair name) t)
                  collect (cons name dir))))))

(defun derived-native-overlays (system cl-repo source-dir)
  "Overlay plists (PARSE-OVERLAY-SPEC form) for SYSTEM's native platforms.
Only for systems with :native-library components or :native-platforms."
  (when (or (getf cl-repo :native-platforms) (native-library-components system))
    (loop for (pair . dir) in (native-platform-directories cl-repo source-dir)
          collect (multiple-value-bind (os arch) (%split-pair pair)
                    (list :platform (list :os os :arch arch)
                          :layers (list (list :role "native-library"
                                              :files (native-overlay-files system pair dir))))))))

(defun auto-package-spec (system-name &key (derive-native-overlays t))
  "Auto-generate a package-spec by introspecting a loaded ASDF system.
   Reads OCI packaging metadata from the system's :properties under :cl-repo.

   Provides resolution order:
     1. Explicit :cl-repo :provides from .asd :properties
     2. Auto-discovered from *.asd files in source-dir
     3. Fallback: (list system-name)

   Native overlays: explicit :overlays, after the ones derived from the
   platform directories (DERIVED-NATIVE-OVERLAYS) unless DERIVE-NATIVE-OVERLAYS
   is NIL (the CI native publish builds them from its artifact directories)."
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
                   :depends-on (collect-external-depends-on system)
                   :provides provides
                   :cffi-libraries (or (getf cl-repo :cffi-libraries)
                                       (mapcar #'asdf:component-name
                                               (native-library-components system)))
                   ;; Explicit :overlays (named flavours, odd layouts) come after
                   ;; the derived ones.
                   :overlays (mapcar #'parse-overlay-spec
                                     (append (when (and derive-native-overlays
                                                        ;; explicit platform overlays win;
                                                        ;; named ones (cuda) add on top
                                                        (notany (lambda (o) (null (getf o :name)))
                                                                (getf cl-repo :overlays)))
                                               (derived-native-overlays system cl-repo source-dir))
                                             (getf cl-repo :overlays))))))

(defmethod asdf:perform ((op package-op) (system asdf:system))
  (let* ((spec (auto-package-spec (asdf:component-name system)))
         (result (build-package spec)))
    (msg "~&Package built: ~a~%  Index digest: ~a~%  Blobs: ~d~%  Manifests: ~d~%"
            (asdf:component-name system)
            (cl-repository-packager/build-matrix:build-result-index-digest result)
            (length (cl-repository-packager/build-matrix:build-result-blobs result))
            (length (cl-repository-packager/build-matrix:build-result-manifests result)))
    result))
