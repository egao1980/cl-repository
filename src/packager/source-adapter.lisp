(defpackage :cl-repository-packager/source-adapter
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg #:*dry-run*)
  (:import-from :cl-oci-client/registry #:registry #:make-registry)
  (:import-from :cl-oci-client/pull #:pull-manifest)
  (:import-from :cl-repository-packager/asdf-plugin
                #:auto-package-spec
                #:discover-provided-systems)
  (:import-from :cl-repository-packager/build-matrix
                #:build-package
                #:package-spec
                #:package-spec-name
                #:package-spec-version
                #:package-spec-depends-on
                #:package-spec-provides
                #:package-spec-source-url
                #:package-spec-revision
                #:build-result)
  (:import-from :cl-repository-packager/publisher #:publish-package)
  (:export #:github-repo-reference-p
           #:normalize-github-repo
           #:github-repo-url
           #:clone-git-source
           #:ensure-dependencies-published
           #:discover-project-systems
           #:build-packages-from-source
           #:build-package-from-source
           #:build-package-from-github))
(in-package :cl-repository-packager/source-adapter)

(defun github-repo-reference-p (value)
  "Return T when VALUE looks like owner/repo."
  (and (stringp value)
       (= (count #\/ value) 1)
       (not (search "://" value))
       (not (search " " value))))

(defun normalize-github-repo (repo-or-url)
  "Normalize owner/repo or github URL into owner/repo."
  (cond
    ((github-repo-reference-p repo-or-url) repo-or-url)
    ((and (stringp repo-or-url) (search "github.com/" repo-or-url))
     (let* ((marker (search "github.com/" repo-or-url))
            (start (+ marker (length "github.com/")))
            (tail (subseq repo-or-url start))
            (without-git (if (and (>= (length tail) 4)
                                  (string= ".git" tail :start1 (- (length tail) 4)))
                             (subseq tail 0 (- (length tail) 4))
                             tail))
            (trimmed (if (and (> (length without-git) 0)
                              (char= (char without-git (1- (length without-git))) #\/))
                         (subseq without-git 0 (1- (length without-git)))
                         without-git)))
       (unless (github-repo-reference-p trimmed)
         (error "Unsupported GitHub reference: ~a" repo-or-url))
       trimmed))
    (t
     (error "Unsupported GitHub reference: ~a" repo-or-url))))

(defun github-repo-url (repo-or-url)
  "Build canonical https URL for a GitHub repository."
  (let ((normalized (normalize-github-repo repo-or-url)))
    (format nil "https://github.com/~a.git" normalized)))

(defun make-temp-source-root ()
  "Create a unique temp directory for source checkout."
  (let* ((stamp (get-universal-time))
         (token (random 1000000))
         (root (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-source-~a-~a/" stamp token)
                                 (uiop:temporary-directory)))))
    (ensure-directories-exist root)
    root))

(defun trim-output (value)
  "Trim whitespace from command output VALUE."
  (string-trim '(#\Space #\Tab #\Newline #\Return) value))

(defun run-git (&rest args)
  "Run git ARGS and return stdout as a string."
  (trim-output
   (uiop:run-program (append (list "git") args)
                     :output :string
                     :error-output :output)))

(defun clone-git-source (repo-url &key ref)
  "Clone REPO-URL to a temporary directory.
Returns (values source-dir revision cleanup-fn)."
  (let* ((root (make-temp-source-root))
         (source-dir (merge-pathnames "source/" root)))
    (run-git "clone" "--quiet" "--depth" "1" repo-url (namestring source-dir))
    (when ref
      (handler-case
          (run-git "-C" (namestring source-dir) "checkout" "--quiet" ref)
        (error ()
          (handler-case
              (progn
                (run-git "-C" (namestring source-dir) "fetch" "--quiet" "--depth" "1" "origin" ref)
                (run-git "-C" (namestring source-dir) "checkout" "--quiet" "FETCH_HEAD"))
            (error (err)
              (error "Unable to resolve git ref ~a for ~a: ~a" ref repo-url err))))))
    (let ((revision (run-git "-C" (namestring source-dir) "rev-parse" "HEAD")))
      (values source-dir revision
              (lambda ()
                (when (probe-file root)
                  (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))))

(defun resolve-system-name (source-dir explicit-system-name)
  "Resolve system name in SOURCE-DIR."
  (let ((systems (discover-provided-systems source-dir)))
    (cond
      ((null systems)
       (error "No .asd systems found in source directory: ~a" source-dir))
      (explicit-system-name
       (unless (member explicit-system-name systems :test #'string=)
         (error "Requested system ~a not found. Available systems: ~{~a~^, ~}"
                explicit-system-name systems))
       explicit-system-name)
      ((= (length systems) 1)
       (first systems))
      (t
       (error "Multiple systems found (~{~a~^, ~}). Please pass --system." systems)))))

(defun discover-project-systems (source-dir)
  "Return sorted system names discovered in SOURCE-DIR."
  (sort (copy-list (or (discover-provided-systems source-dir) nil)) #'string<))

(defun dep-name (dep)
  "Extract dependency name from DEP (string or cons)."
  (etypecase dep
    (string dep)
    (cons (car dep))))

(defun dep-version (dep)
  "Extract dependency version token from DEP when present."
  (etypecase dep
    (string nil)
    (cons (cdr dep))))

(defun dependency-skipped-p (spec dependency-name)
  "Return T when DEPENDENCY-NAME is provided by SPEC itself."
  (or (string= dependency-name (package-spec-name spec))
      (member dependency-name (package-spec-provides spec) :test #'string=)))

(defun dependency-published-p (registry namespace dependency-name &key version)
  "Return T when DEPENDENCY-NAME is already present in target registry namespace."
  (let* ((repo (format nil "~a/~a" namespace dependency-name))
         (tag (or version "latest")))
    (handler-case
        (progn
          (pull-manifest registry repo tag)
          t)
      (error ()
        ;; Version token in dependency constraints is often lower-bound, not exact tag.
        ;; Fallback to latest as an existence probe.
        (handler-case
            (progn
              (pull-manifest registry repo "latest")
              t)
          (error ()
            nil))))))

(defun local-source-system-p (system-name)
  "Return source-dir pathname when SYSTEM-NAME has a local ASDF source directory."
  (let ((system (asdf:find-system system-name nil)))
    (when system
      (let ((source-dir (ignore-errors (asdf:system-source-directory system))))
        (when (and source-dir (probe-file source-dir))
          source-dir)))))

(defun ensure-dependencies-published (spec registry namespace
                                      &key publish-missing recursive (skip-catalog t)
                                        publish-ql-dependencies deps-dist-url)
  "Resolve SPEC dependencies for target REGISTRY/NAMESPACE.
When PUBLISH-MISSING is true, publish local dependencies that are not present in registry.
Dependencies that are local-only (installed via Quicklisp/qlot/local checkout) are accepted.
Signals an error for unresolved dependencies."
  (let ((reg (etypecase registry
               (registry registry)
               (string (make-registry registry))))
        (visited (make-hash-table :test 'equal))
        (published nil)
        (unresolved nil))
    (labels ((process-spec (current-spec)
               (dolist (dep (package-spec-depends-on current-spec))
                 (let* ((name (dep-name dep))
                        (version (dep-version dep)))
                   (unless (or (dependency-skipped-p current-spec name)
                               (gethash name visited))
                     (setf (gethash name visited) t)
                     (cond
                       ((dependency-published-p reg namespace name :version version)
                        (msg "~&Dependency ~a already published in ~a.~%" name namespace))
                       ((local-source-system-p name)
                        (if publish-missing
                            (handler-case
                                (let* ((dep-spec (auto-package-spec name))
                                       (dep-tag (or (package-spec-version dep-spec) "latest")))
                                  (when recursive
                                    (process-spec dep-spec))
                                  (publish-package reg namespace dep-tag
                                                   (build-package dep-spec)
                                                   dep-spec
                                                   :skip-catalog skip-catalog)
                                  (pushnew name published :test #'string=)
                                  (msg "~&Published missing dependency ~a:~a~%" name dep-tag))
                              (error (err)
                                (push (format nil "~a (local publish failed: ~a)" name err)
                                      unresolved)))
                            (msg "~&Dependency ~a is local-only (Quicklisp/qlot/local).~%" name)))
                       ((asdf:find-system name nil)
                        (msg "~&Dependency ~a is an ASDF/system dependency; skipping publish.~%" name))
                       (t
                        (push (cons name version)
                              unresolved)))))))
             (try-publish-from-dist ()
               (when (and unresolved publish-ql-dependencies)
                 (let* ((registry-url (etypecase registry
                                        (registry (error "publish-ql-dependencies requires registry URL string input"))
                                        (string registry)))
                        (missing-names
                          (remove-duplicates
                           (mapcar #'car unresolved)
                           :test #'string=))
                        (dist-url (or deps-dist-url "https://beta.quicklisp.org/dist/quicklisp.txt"))
                        (filter (format nil "~{~a~^,~}" missing-names))
                        (export-fn (find-symbol "EXPORT-DIST" :cl-repository-ql-exporter/exporter)))
                   (unless export-fn
                     (error "Quicklisp/Ultralisp exporter not loaded; enable cl-repository-ql-exporter first."))
                   (msg "~&Attempting dist export for unresolved deps from ~a: ~{~a~^, ~}~%"
                        dist-url missing-names)
                   (funcall export-fn dist-url registry-url
                            :namespace namespace
                            :filter filter
                            :incremental t
                            :dry-run *dry-run*)
                   (setf unresolved
                         (remove-if (lambda (dep)
                                      (dependency-published-p reg namespace (car dep) :version (cdr dep)))
                                    unresolved)))))
             (finalize ()
               (try-publish-from-dist)
               (when unresolved
                 (let ((unresolved-labels
                         (mapcar (lambda (dep)
                                   (if (cdr dep)
                                       (format nil "~a@~a" (car dep) (cdr dep))
                                       (car dep)))
                                 (nreverse unresolved))))
                   (if (and *dry-run* publish-ql-dependencies)
                       (msg "~&[dry-run] Remaining unresolved after fallback check (expected in dry-run): ~{~a~^, ~}~%"
                            unresolved-labels)
                       (error "Unresolved dependencies for ~a: ~{~a~^, ~}.~@[ Enable --publish-dependencies to auto-publish local deps.~]~@[ Enable --publish-ql-dependencies for dist fallback.~]"
                              (package-spec-name spec)
                              unresolved-labels
                              (not publish-missing)
                              (not publish-ql-dependencies)))))))
      (process-spec spec)
      (finalize)
      (nreverse published))))

(defun build-packages-from-source (source-dir &key source-url revision isolate-provides)
  "Build all systems discovered in SOURCE-DIR.
Returns an alist of (spec . result)."
  (let* ((systems (discover-project-systems source-dir))
         (source-dir-ns (namestring source-dir))
         (built nil))
    (when (null systems)
      (error "No .asd systems found in source directory: ~a" source-dir))
    (asdf:initialize-source-registry
     `(:source-registry (:tree ,source-dir-ns) :inherit-configuration))
    (dolist (system-name systems)
      (asdf:clear-system system-name)
      (let ((spec (auto-package-spec system-name)))
        (setf (package-spec-source-url spec) source-url)
        (setf (package-spec-revision spec) revision)
        (when isolate-provides
          ;; In bulk mode publish each system as its own canonical package.
          (setf (package-spec-provides spec) (list (package-spec-name spec))))
        (push (cons spec (build-package spec)) built)))
    (nreverse built)))

(defun build-package-from-source (source-dir &key system-name source-url revision)
  "Build package from SOURCE-DIR and return (values spec result)."
  (let* ((resolved-system (resolve-system-name source-dir system-name))
         (source-dir-ns (namestring source-dir)))
    (asdf:initialize-source-registry
     `(:source-registry (:tree ,source-dir-ns) :inherit-configuration))
    (asdf:clear-system resolved-system)
    (let ((spec (auto-package-spec resolved-system)))
      (setf (package-spec-source-url spec) source-url)
      (setf (package-spec-revision spec) revision)
      (values spec (build-package spec)))))

(defun build-package-from-github (repo-or-url &key ref system-name)
  "Build package from a GitHub repository.
Returns (values spec result cleanup-fn)."
  (let ((repo-url (github-repo-url repo-or-url)))
    (multiple-value-bind (source-dir revision cleanup-fn)
        (clone-git-source repo-url :ref ref)
      (multiple-value-bind (spec result)
          (build-package-from-source source-dir
                                     :system-name system-name
                                     :source-url (format nil "https://github.com/~a"
                                                         (normalize-github-repo repo-or-url))
                                     :revision revision)
        (values spec result cleanup-fn)))))
