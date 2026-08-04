(defpackage :cl-repository-client/quickload
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:make-registry)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-blob)
  (:import-from :cl-oci-client/content-discovery #:list-tags #:list-referrers)
  (:import-from :cl-oci-client/conditions #:registry-error)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests)
  (:import-from :cl-oci/manifest #:manifest #:manifest-artifact-type #:manifest-config
                #:manifest-annotations)
  (:import-from :cl-oci/descriptor #:descriptor-digest #:descriptor-annotations)
  (:import-from :cl-oci/digest #:format-digest)
  (:import-from :cl-oci/media-types #:+cl-system-name-anchor-v1+ #:+cl-system-artifact-type+)
  (:import-from :cl-oci/annotations #:+ann-version+ #:+cl-alias-for+)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :cl-oci/config #:cl-system-config)
  (:import-from :cl-repository-client/installer #:install-system #:install-result
                #:install-result-path #:install-result-name #:install-result-version
                #:install-result-index-digest #:install-result-source-digest
                #:install-result-overlay-digest #:install-result-registry-url
                #:systems-root #:system-install-path)
  (:import-from :cl-repository-client/digest-cache
                #:digest-already-installed-p #:record-installed-digest #:load-digest-cache)
  (:import-from :cl-repository-client/constraint-builder
                #:build-install-plan #:find-missing-deps #:dependency-resolution-error)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version)
  (:import-from :cl-repository-client/asdf-integration #:configure-asdf-source-registry
                #:load-system-init-files)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-entry #:add-lockfile-entry)
  (:import-from :cl-repository-client/protected-systems
                #:ensure-snapshot #:system-protected-p
                #:*protected-system-prefixes*)
  (:import-from :cl-repository-client/config
                #:load-merged-config #:config-value)
  (:import-from :cl-repository-client/source-policy
                #:*source-policy* #:*source-rules* #:*default-source*
                #:apply-source-config #:call-with-policy-overrides
                #:source-for #:ql-allowed-p #:system-denied-p)
  (:import-from :babel #:octets-to-string)
  (:export #:*registries*
           #:add-registry
           #:ensure-systems
           #:ensure-system-dependencies
           #:installed-system-version
           #:load-system))
(in-package :cl-repository-client/quickload)

(defvar *registries* nil
  "Ordered list of OCI registries to search.
   Each entry is (URL &key namespace type).
   TYPE is :cl-repo (default) or :ocicl.
   Example:
     ((\"http://localhost:5050\" :namespace \"cl-systems\")
      (\"https://ghcr.io\" :namespace \"ocicl\" :type :ocicl))")

(defun add-registry (url &key (namespace "cl-systems") (priority :append) (type :cl-repo))
  "Add a registry to *registries*.
   PRIORITY is :prepend (search first) or :append (search last).
   TYPE is :cl-repo (default) or :ocicl for OCICL-format registries.
   Avoids duplicates by URL+namespace."
  (let ((entry (list url :namespace namespace :type type)))
    (unless (find-if (lambda (e)
                       (and (string= (first e) url)
                            (string= (registry-namespace e) namespace)))
                     *registries*)
      (ecase priority
        (:prepend (push entry *registries*))
        (:append (setf *registries* (append *registries* (list entry)))))))
  *registries*)

(defun registry-url (entry) (first entry))
(defun registry-namespace (entry) (getf (rest entry) :namespace "cl-systems"))
(defun registry-type (entry) (getf (rest entry) :type :cl-repo))

;;; System presence checks

(defun system-already-installed-p (name)
  "Check if any version of NAME is installed locally, following symlinks."
  (let ((dir (merge-pathnames (format nil "~a/" name) (systems-root))))
    (or (and (probe-file dir)
             (uiop:subdirectories dir))
        (handler-case
            (let ((real (truename dir)))
              (and real (uiop:subdirectories real)))
          (error () nil)))))

(defun installed-system-version (name)
  "Return installed version string for NAME, or NIL."
  (let ((dir (merge-pathnames (format nil "~a/" name) (systems-root))))
    (handler-case
        (let ((real-dir (truename dir)))
          (when real-dir
            (let ((subdirs (uiop:subdirectories real-dir)))
              (when subdirs
                (car (last (pathname-directory (first (last subdirs)))))))))
      (error () nil))))

;;; Lockfile integration

(defun record-lockfile-entry (result)
  "Create a lockfile entry from an INSTALL-RESULT and append it to cl-repo.lock."
  (handler-case
      (when (and (install-result-name result)
                 (install-result-version result))
        (add-lockfile-entry
         (make-instance 'lockfile-entry
                        :system (install-result-name result)
                        :version (install-result-version result)
                        :index-digest (or (install-result-index-digest result) "")
                        :source-digest (install-result-source-digest result)
                        :overlay-digest (install-result-overlay-digest result)
                        :registry (or (install-result-registry-url result) ""))))
    (error (e)
      (msg "~&; cl-repo: warning: could not update lockfile: ~a~%" e))))

;;; Direct system install (for single system, bypasses SAT)

(defun find-system-in-registry (reg-url namespace system-name &key version (type :cl-repo))
  "Find SYSTEM-NAME in a registry. Returns (values repo tag) or NIL.
   If VERSION given, uses it directly. Otherwise discovers via tags or anchor.
   For :ocicl registries, the repo is just the system name (no namespace nesting)."
  (let* ((repo (if (eq type :ocicl)
                   (format nil "~a/~a" namespace system-name)
                   (format nil "~a/~a" namespace system-name)))
         (reg (make-registry reg-url)))
    (handler-case
        (if version
            (values repo version)
            (let ((tags (list-tags reg repo)))
              (if tags
                  (let ((version-tags (remove "latest" tags :test #'string=)))
                    (if version-tags
                        (values repo (select-preferred-version version-tags))
                        (values repo (first tags))))
                  (unless (eq type :ocicl)
                    (find-via-anchor reg repo)))))
      (error () nil))))

(defun find-via-anchor (registry repo)
  "Try to find system via system-name anchor at :latest."
  (handler-case
      (let ((obj (pull-manifest registry repo "latest")))
        (when (and (typep obj 'manifest)
                   (string= (manifest-artifact-type obj) +cl-system-name-anchor-v1+))
          ;; It's a system-name anchor -- read alias-for
          (let* ((ann (manifest-annotations obj))
                 (alias-for (gethash +cl-alias-for+ ann))
                 (version (gethash +ann-version+ ann)))
            (when (and alias-for version)
              ;; The actual package is at the alias-for repo
              (let ((alias-repo (format nil "~a/~a"
                                        (subseq repo 0 (position #\/ repo :from-end t))
                                        alias-for)))
                (values alias-repo version))))))
    (error () nil)))

(defun ensure-system-installed (name &key version)
  "Install NAME from configured registries. Returns INSTALL-RESULT or NIL."
  (dolist (entry *registries* nil)
    (let ((url (registry-url entry))
          (ns (registry-namespace entry))
          (type (registry-type entry)))
      (handler-case
          (multiple-value-bind (repo tag)
              (find-system-in-registry url ns name :version version :type type)
            (when (and repo tag)
              (msg "~&; cl-repo: found ~a:~a in ~a (~a)~%" name tag url type)
              (return-from ensure-system-installed
                (install-system url repo tag :type type))))
        (error (e)
          (msg "~&; cl-repo: ~a not in ~a (~a)~%" name url e))))))

;;; Missing deps accumulator (set by compute-install-plan, consumed by load-system)

(defvar *missing-deps-accumulator* nil
  "List of dep names not found in OCI registries during the last compute-install-plan.")

;;; Config loading

(defvar *config-loaded* nil
  "T after config has been loaded for the current session.")

(defun ensure-config-loaded (&optional explicit-config-path)
  "Load and apply cl-repo.conf (global + project) if not already done."
  (unless *config-loaded*
    (let ((config (load-merged-config explicit-config-path)))
      (when config
        (apply-source-config config)
        ;; Apply registries from config
        (let ((registries (config-value config :registries)))
          (dolist (reg-entry (reverse registries))
            (when (and (listp reg-entry) (stringp (first reg-entry)))
              (add-registry (first reg-entry)
                            :namespace (or (getf (rest reg-entry) :namespace) "cl-systems")
                            :priority :append))))
        ;; Apply protected system prefixes from config
        (let ((protect (config-value config :protect)))
          (dolist (p protect)
            (pushnew p *protected-system-prefixes*
                     :test #'string=)))))
    (setf *config-loaded* t)))

;;; Quicklisp fallback

(defun quicklisp-available-p ()
  "T if Quicklisp is loaded in the image."
  (not (null (find-package :ql))))

(defun try-quicklisp-fallback (missing-deps)
  "Attempt to install MISSING-DEPS via Quicklisp. Returns list of successfully loaded names."
  (when (and missing-deps (quicklisp-available-p))
    (let ((loaded nil))
      (msg "~&; cl-repo: ~d deps not in OCI registries, trying Quicklisp fallback: ~{~a~^, ~}~%"
           (length missing-deps) missing-deps)
      (dolist (dep missing-deps)
        (if (ql-allowed-p dep)
            (handler-case
                (progn
                  (uiop:symbol-call :ql :quickload dep :silent t)
                  (push dep loaded)
                  (msg "~&; cl-repo: ql:quickload ~a OK~%" dep))
              (error (e)
                (msg "~&; cl-repo: ql:quickload ~a failed: ~a~%" dep e)))
            (msg "~&; cl-repo: skipping QL fallback for ~a (source policy: ~a)~%"
                 dep (source-for dep))))
      loaded)))

;;; Main entry points

(defun ensure-systems (systems &key silent version force
                                    with sources deny allow default-source
                                    config-path)
  "Resolve and install SYSTEMS from OCI registries, then Quicklisp for leftovers.
   Does **not** ASDF-load — use for CI install before overlays are wired.
   Same keyword args as LOAD-SYSTEM (SOURCES/DENY/ALLOW/DEFAULT-SOURCE, WITH, …).

   Resolution order per system: configured registries (e.g. ghcr.io packages
   published from GitHub via cl-stack-systems) → QL fallback when policy allows."
  (ensure-config-loaded config-path)
  (call-with-policy-overrides
   sources deny allow default-source
   (lambda ()
     (let* ((*quiet* (or *quiet* silent))
            (system-list (mapcar (lambda (s) (string-downcase (string s)))
                                 (if (listp systems) systems (list systems)))))
       (ensure-snapshot)
       (load-digest-cache)
       (let ((plan (compute-install-plan system-list :version version :force force
                                                     :with with)))
         (dolist (entry plan)
           (let ((name (car entry))
                 (ver (cdr entry)))
             (unless (or (system-denied-p name)
                         (and (not force)
                              (system-already-installed-p name)
                              (let ((iv (installed-system-version name)))
                                (and iv (string= iv (princ-to-string ver))))))
               (let ((result (ensure-system-installed name :version ver)))
                 (when result
                   (configure-asdf-source-registry)
                   (record-lockfile-entry result)
                   (when (install-result-index-digest result)
                     (record-installed-digest (install-result-index-digest result)
                                              (install-result-path result))))))))
         ;; QL only after all OCI pulls — loading cffi/cl+ssl mid-flight breaks HTTPS.
         (when *missing-deps-accumulator*
           (try-quicklisp-fallback *missing-deps-accumulator*))
         (configure-asdf-source-registry)
         system-list)))))

(defun asdf-dep-name (dep)
  "Normalize an ASDF :depends-on entry to a downcased system name, or NIL if skipped."
  (cond
    ((stringp dep) (string-downcase dep))
    ((and (symbolp dep) (not (keywordp dep)))
     (string-downcase (symbol-name dep)))
    ((and (consp dep) (eq (first dep) :version) (>= (length dep) 2))
     (asdf-dep-name (second dep)))
    ((and (consp dep) (eq (first dep) :feature) (>= (length dep) 3))
     (when (uiop:featurep (second dep))
       (asdf-dep-name (third dep))))
    ((and (consp dep) (eq (first dep) :require))
     nil)
    (t nil)))

(defun system-direct-deps (system)
  "Direct ASDF dependency names for SYSTEM (string or asdf:system)."
  (let ((sys (if (typep system 'asdf:system)
                 system
                 (asdf:find-system system nil))))
    (when sys
      (remove nil (mapcar #'asdf-dep-name (asdf:system-depends-on sys))))))

(defun collect-missing-asdf-deps (local-roots &optional extras)
  "Walk ASDF :depends-on from LOCAL-ROOTS (findable systems). Return names that
   are not yet findable via ASDF — those need OCI/QL install. EXTRAS are always
   considered (CI-only systems). Does not return LOCAL-ROOTS themselves."
  (let ((seen (make-hash-table :test #'equal))
        (local (mapcar (lambda (s) (string-downcase (string s))) local-roots))
        (missing '()))
    (labels ((local-p (n) (member n local :test #'string=))
             (walk (name)
               (let ((n (string-downcase (string name))))
                 (unless (gethash n seen)
                   (setf (gethash n seen) t)
                   (cond
                     ((local-p n)
                      (let ((sys (asdf:find-system n nil)))
                        (when sys
                          (dolist (d (system-direct-deps sys))
                            (walk d)))))
                     ((asdf:find-system n nil)
                      (dolist (d (system-direct-deps n))
                        (walk d)))
                     (t
                      (pushnew n missing :test #'string=)))))))
      (dolist (r local) (walk r))
      (dolist (e (mapcar (lambda (s) (string-downcase (string s)))
                         (uiop:ensure-list extras)))
        (walk e))
      (nreverse missing))))

(defun ensure-system-dependencies (system-name &key (also-tests t) with silent version force
                                                    sources deny allow default-source
                                                    config-path)
  "Install dependency closure for a **local** SYSTEM-NAME (checkout on CL_SOURCE_REGISTRY).

   Walks ASDF :depends-on (transitively while systems are findable). Missing names
   go through ENSURE-SYSTEMS (OCI registries → QL fallback). Does not install or
   ASDF-load SYSTEM-NAME itself.

   ALSO-TESTS (default T): also walk SYSTEM-NAME/tests when that system exists.
   WITH: extra CI-only systems not in the .asd (e.g. event-backend-libuv, cl-stack-ssl)."
  (let* ((name (string-downcase (string system-name)))
         (sys (or (asdf:find-system name nil)
                  (error "ensure-system-dependencies: system ~a not findable via ASDF ~
(is the checkout on CL_SOURCE_REGISTRY?)" name)))
         (test-name (format nil "~a/tests" name))
         (local-roots (list name))
         (extras (mapcar (lambda (s) (string-downcase (string s)))
                         (uiop:ensure-list with))))
    (declare (ignore sys))
    (when also-tests
      (let ((ts (if (stringp also-tests)
                    (string-downcase also-tests)
                    test-name)))
        (when (asdf:find-system ts nil)
          (push ts local-roots))))
    (let ((targets (collect-missing-asdf-deps local-roots extras)))
      (msg "~&; cl-repo: ensure deps for local ~a → ~{~a~^, ~}~%" name targets)
      (when targets
        (ensure-systems targets
                        :silent silent :version version :force force
                        :sources sources :deny deny :allow allow
                        :default-source default-source
                        :config-path config-path)))
    (values)))

(defun load-system (systems &key silent version force
                                  with sources deny allow default-source
                                  config-path)
  "Install (if needed) and load Common Lisp systems from OCI registries.
   Uses SAT solver for transitive dependency resolution with version constraints.

   SYSTEMS: system name (string/symbol) or list of them.
   SILENT: suppress output. VERSION: pin specific tag. FORCE: re-resolve even if installed.
   WITH: extra deps resolved alongside (like uv --with). List of strings or (name :version v).
   SOURCES: per-system source overrides. Alist ((name :ql) (name :oci) ...).
   DENY: deny rules. List of strings or (:deny name :from registry) forms.
   ALLOW: allow-from rules. List of (:allow name :from registry) forms.
   DEFAULT-SOURCE: :oci | :ql | :any — override *default-source* for this call.
   CONFIG-PATH: explicit cl-repo.conf path (overrides project discovery).

   Usage:
     (cl-repo:load-system \"alexandria\")
     (cl-repo:load-system \"grpc\" :with '(\"rove\") :sources '((\"float-features\" :ql)))
     (cl-repo:load-system \"my-app\" :force t :deny '(\"bad-lib\"))"
  (let ((system-list (ensure-systems systems
                                     :silent silent :version version :force force
                                     :with with :sources sources :deny deny
                                     :allow allow :default-source default-source
                                     :config-path config-path)))
    (call-with-policy-overrides
     sources deny allow default-source
     (lambda ()
       (let ((*quiet* (or *quiet* silent)))
         (load-system-init-files)
         (dolist (sys system-list)
           (msg "~&; cl-repo: loading ~a~%" sys)
           (handler-case (asdf:load-system sys)
             (error (e)
               (msg "~&; cl-repo: failed to load ~a: ~a~%" sys e)))))))
    (if (= (length system-list) 1)
        (first system-list)
        system-list)))

(defun compute-install-plan (system-names &key version force with)
  "Use SAT solver to compute full transitive install plan.
   Pins already-installed systems unless FORCE is true.
   Skips systems that are protected (see SYSTEM-PROTECTED-P).
   WITH: extra systems to resolve alongside (separate SAT passes).
   Sets *missing-deps-accumulator* as a side-effect."
  (let ((plan nil))
    (setf *missing-deps-accumulator* nil)
    ;; Resolve main systems
    (dolist (name-raw system-names)
      (let ((name (string-downcase (string name-raw))))
        (if (and (not force) (or (asdf:find-system name nil)
                                 (system-protected-p name)))
            (msg "~&; cl-repo: ~a already available via ASDF~%" name)
            (handler-case
                (multiple-value-bind (resolved missing)
                    (build-install-plan name (or version :latest) *registries* :force force)
                  (dolist (entry resolved)
                    (unless (find (car entry) plan :key #'car :test #'string=)
                      (push entry plan)))
                  (dolist (m missing)
                    (pushnew m *missing-deps-accumulator* :test #'string=)))
              (dependency-resolution-error (e)
                (msg "~&; cl-repo: ~a~%" e))
              (error (e)
                (msg "~&; cl-repo: SAT resolution unavailable for ~a (~a), trying direct~%" name e)
                (unless (system-already-installed-p name)
                  (push (cons name version) plan)))))))
    ;; Resolve :with extras (separate SAT pass each)
    (dolist (extra-raw (or with nil))
      (multiple-value-bind (extra-name extra-version)
          (if (consp extra-raw)
              (values (first extra-raw) (getf (rest extra-raw) :version))
              (values (string extra-raw) nil))
        (let ((name (string-downcase (string extra-name))))
          (unless (or (asdf:find-system name nil)
                      (find name plan :key #'car :test #'string=))
            (handler-case
                (multiple-value-bind (resolved missing)
                    (build-install-plan name (or extra-version :latest) *registries* :force force)
                  (dolist (entry resolved)
                    (unless (find (car entry) plan :key #'car :test #'string=)
                      (push entry plan)))
                  (dolist (m missing)
                    (pushnew m *missing-deps-accumulator* :test #'string=)))
              (dependency-resolution-error (e)
                (msg "~&; cl-repo: --with ~a: ~a~%" name e))
              (error (e)
                (msg "~&; cl-repo: --with ~a failed: ~a~%" name e)))))))
    (nreverse plan)))
