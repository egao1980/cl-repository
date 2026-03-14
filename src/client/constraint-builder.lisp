(defpackage :cl-repository-client/constraint-builder
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:import-from :cl-oci-client/registry #:make-registry)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-blob)
  (:import-from :cl-oci-client/content-discovery #:list-tags)
  (:import-from :cl-oci-client/conditions #:registry-error)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests)
  (:import-from :cl-oci/manifest #:manifest #:manifest-config)
  (:import-from :cl-oci/descriptor #:descriptor-digest)
  (:import-from :cl-oci/digest #:format-digest)
  (:import-from :cl-oci/config #:cl-system-config #:config-system-name #:config-version
                #:config-depends-on #:config-provides)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :babel #:octets-to-string)
  (:import-from :cl-repository-client/solver
                #:sat-true #:sat-var #:sat-and #:sat-or #:sat-not #:sat-imply #:sat-solve)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version)
  (:export #:build-install-plan
           #:scan-installed-systems
           #:dependency-resolution-error))
(in-package :cl-repository-client/constraint-builder)

(define-condition dependency-resolution-error (error)
  ((message :initarg :message :reader resolution-error-message))
  (:report (lambda (c s) (format s "Dependency resolution failed: ~a" (resolution-error-message c)))))

;;; Caches for registry queries

(defvar *version-cache* nil)
(defvar *config-cache* nil)

(defun dep-name (dep)
  (etypecase dep (string dep) (cons (car dep))))

(defun dep-version (dep)
  (etypecase dep (string nil) (cons (cdr dep))))

(defun pkg-var (name version)
  "Create SAT variable name for a package-version pair."
  (format nil "~a-v~a" name version))

(defun parse-pkg-var (var-name)
  "Parse a SAT variable name back to (name . version)."
  (let ((pos (search "-v" var-name :from-end t)))
    (when pos
      (cons (subseq var-name 0 pos) (subseq var-name (+ pos 2))))))

;;; Scanning installed systems

(defun scan-installed-systems ()
  "Return alist of (name . version) for locally installed systems."
  (let ((root (systems-root))
        (installed nil))
    (when (probe-file root)
      (dolist (sys-dir (uiop:subdirectories root))
        (let ((name (car (last (pathname-directory sys-dir)))))
          ;; Follow symlinks to canonical
          (let ((real-dir (truename sys-dir)))
            (declare (ignore real-dir))
            (dolist (ver-dir (uiop:subdirectories sys-dir))
              (let ((ver (car (last (pathname-directory ver-dir)))))
                (pushnew (cons name ver) installed
                         :test (lambda (a b) (string= (car a) (car b))))))))))
    installed))

;;; Registry queries (cached)

(defun fetch-available-versions (name registries)
  "Get available versions for NAME from registries. Cached."
  (or (gethash name *version-cache*)
      (let ((versions nil))
        (dolist (entry registries)
          (let* ((url (first entry))
                 (ns (getf (rest entry) :namespace "cl-systems"))
                 (repo (format nil "~a/~a" ns name))
                 (reg (make-registry url)))
            (handler-case
                (let ((tags (list-tags reg repo)))
                  (when tags
                    (dolist (tag tags)
                      (pushnew tag versions :test #'string=))))
              (error () nil))))
        (setf (gethash name *version-cache*) versions)
        versions)))

(defun fetch-config (name version registries)
  "Fetch config blob for NAME at VERSION. Cached."
  (let ((key (cons name version)))
    (or (gethash key *config-cache*)
        (let ((config (fetch-config-from-registry name version registries)))
          (when config
            (setf (gethash key *config-cache*) config))
          config))))

(defun fetch-config-from-registry (name version registries)
  "Actually fetch config from a registry."
  (dolist (entry registries nil)
    (let* ((url (first entry))
           (ns (getf (rest entry) :namespace "cl-systems"))
           (repo (format nil "~a/~a" ns name))
           (reg (make-registry url)))
      (handler-case
          (let ((obj (pull-manifest reg repo version)))
            (etypecase obj
              (image-index
               (let* ((descs (image-index-manifests obj))
                      (first-desc (first descs)))
                 (when first-desc
                   (let* ((mfst (pull-manifest reg repo (format-digest (descriptor-digest first-desc))))
                          (cfg-blob (pull-blob reg repo
                                               (format-digest (descriptor-digest
                                                               (manifest-config mfst)))))
                          (cfg (from-json 'cl-system-config
                                          (babel:octets-to-string cfg-blob :encoding :utf-8))))
                     (return-from fetch-config-from-registry cfg)))))
              (manifest
               (let* ((cfg-blob (pull-blob reg repo
                                           (format-digest (descriptor-digest
                                                           (manifest-config obj)))))
                      (cfg (from-json 'cl-system-config
                                      (babel:octets-to-string cfg-blob :encoding :utf-8))))
                 (return-from fetch-config-from-registry cfg)))))
        (error () nil)))))

;;; Universe gathering (BFS over dependency graph)

(defun gather-universe (root-name root-version registries installed &key force)
  "Gather the full package universe reachable from ROOT-NAME.
   Returns hash-table: name -> list of (version . config-or-nil)."
  (let ((universe (make-hash-table :test 'equal))
        (queue (list (cons root-name root-version))))
    (loop while queue do
      (let* ((pair (pop queue))
             (name (car pair))
             (requested-version (cdr pair)))
        (unless (gethash name universe)
          (let* ((pinned (and (not force)
                              (cdr (assoc name installed :test #'string=))))
                 (versions (if pinned
                               (list pinned)
                               (or (fetch-available-versions name registries)
                                   (when requested-version (list requested-version))))))
            (when versions
              (let ((entries nil))
                (dolist (ver versions)
                  (let ((config (fetch-config name ver registries)))
                    (push (cons ver config) entries)
                    ;; Enqueue deps
                    (when config
                      (dolist (dep (config-depends-on config))
                        (let ((dn (dep-name dep)))
                          (unless (gethash dn universe)
                            (push (cons dn (dep-version dep)) queue)))))))
                (setf (gethash name universe) (nreverse entries))))))))
    universe))

;;; Formula building

(defun build-formula (root-name root-version universe installed &key force)
  "Build SAT formula from the package universe."
  (let ((terms nil))
    ;; Root must be true
    (push (sat-var (pkg-var root-name root-version)) terms)
    ;; Pin installed systems
    (unless force
      (dolist (pair installed)
        (let* ((name (car pair))
               (version (cdr pair))
               (entries (gethash name universe)))
          (when entries
            (push (sat-var (pkg-var name version)) terms)))))
    ;; For each package in universe
    (maphash
     (lambda (name entries)
       (let ((all-vars (mapcar (lambda (e) (pkg-var name (car e))) entries)))
         ;; Mutual exclusion: at most one version
         (loop for (v1 . rest) on all-vars
               do (dolist (v2 rest)
                    (push (sat-not (sat-and (list (sat-var v1) (sat-var v2)))) terms)))
         ;; Dependency implications
         (dolist (entry entries)
           (let* ((ver (car entry))
                  (config (cdr entry))
                  (entry-var (pkg-var name ver)))
             (when config
               (dolist (dep (config-depends-on config))
                 (let* ((dn (dep-name dep))
                        (dv (dep-version dep))
                        (dep-entries (gethash dn universe)))
                   (when dep-entries
                     (let ((matching (matching-versions dep-entries dn dv)))
                       (when matching
                         (push (sat-imply (sat-var entry-var)
                                          (sat-or (mapcar #'sat-var matching)))
                               terms)))))))))))
     universe)
    (sat-and terms)))

(defun matching-versions (entries dep-name version-constraint)
  "Return list of pkg-var strings for versions of DEP-NAME that satisfy VERSION-CONSTRAINT."
  (let ((result nil))
    (dolist (entry entries)
      (let ((ver (car entry)))
        (when (or (null version-constraint)
                  (version-satisfies-p ver version-constraint))
          (push (pkg-var dep-name ver) result))))
    (nreverse result)))

(defun version-satisfies-p (installed-version required-version)
  "Check if INSTALLED-VERSION satisfies REQUIRED-VERSION constraint.
   Uses asdf:version-satisfies when available, falls back to string>=."
  (handler-case
      (asdf:version-satisfies installed-version required-version)
    (error () (string>= installed-version required-version))))

;;; Main entry point

(defun build-install-plan (root-name root-version registries &key force)
  "Build a complete install plan for ROOT-NAME.
   ROOT-VERSION: specific version string or :latest (auto-discover).
   Returns alist ((name . version) ...) or signals dependency-resolution-error."
  (let ((*version-cache* (make-hash-table :test 'equal))
        (*config-cache* (make-hash-table :test 'equal)))
    ;; Resolve :latest to actual version
    (when (or (eq root-version :latest) (null root-version))
      (let ((versions (fetch-available-versions root-name registries)))
        (unless versions
          (error 'dependency-resolution-error
                 :message (format nil "~a not found in any registry" root-name)))
        (setf root-version (select-preferred-version versions))))
    (let* ((installed (scan-installed-systems))
           (universe (gather-universe root-name root-version registries installed :force force))
           (formula (build-formula root-name root-version universe installed :force force))
           (solution (sat-solve formula)))
      (unless solution
        (error 'dependency-resolution-error
               :message (format nil "Cannot satisfy dependencies for ~a ~a~@[ (conflicts with installed systems; try :force t)~]"
                                root-name root-version (and (not force) installed))))
      ;; Extract install plan: true bindings, exclude already-installed
      (let ((plan nil))
        (dolist (binding solution)
          (when (cdr binding)
            (let ((parsed (parse-pkg-var (car binding))))
              (when parsed
                (let ((name (car parsed))
                      (version (cdr parsed)))
                  (unless (and (not force)
                               (assoc name installed :test #'string=))
                    (push (cons name version) plan)))))))
        (nreverse plan)))))
