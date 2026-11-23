(defpackage :cl-repository-client/constraint-builder
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg #:*quiet*)
  (:import-from :cl-oci-client/registry #:make-registry #:registry-request-batch #:blob-timeout)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-manifest-raw #:pull-blob
                #:head-manifest #:parse-manifest-body #:*default-accept*
                #:remember-pull)
  (:import-from :cl-oci-client/content-discovery #:list-tags #:parse-tag-list)
  (:import-from :cl-oci-client/conditions #:registry-error #:registry-error-status
                #:registry-transport-error)
  (:import-from :cl-oci-client/http #:ensure-http-backend)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests)
  (:import-from :cl-oci/manifest #:manifest #:manifest-config)
  (:import-from :cl-oci/descriptor #:descriptor-digest)
  (:import-from :cl-oci/digest #:format-digest #:compute-digest)
  (:import-from :cl-oci/config #:cl-system-config #:config-system-name #:config-version
                #:config-depends-on #:config-provides)
  (:import-from :cl-oci/system-names #:oci-package-name #:asdf-primary-system-name)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :babel #:octets-to-string)
  (:import-from :cl-repository-client/solver
                #:sat-true #:sat-var #:sat-and #:sat-or #:sat-not #:sat-imply #:sat-solve)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version #:version<)
  (:import-from :cl-repository-client/source-policy
                #:system-denied-p #:registry-allowed-p #:oci-allowed-p)
  (:import-from :cl-repository-client/protected-systems #:implementation-system-p)
  (:import-from :cl-repository-client/dep-satisfy #:system-satisfied-p)
  (:import-from :cl-repository-client/config-store #:stored-entry #:store-entry)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+)
  (:export #:build-install-plan
           #:fetch-available-versions
           #:fetch-versions-batch
           #:list-tags/retry
           #:*tag-list-attempts*
           #:scan-installed-systems
           #:installed-versions
           #:find-missing-deps
           #:dependency-resolution-error
           #:system-lookup-error
           #:system-lookup-error-name
           #:system-lookup-error-failures
           #:with-resolution-cache
           #:*resolution-cache*
           #:make-resolution-cache
           #:call-with-resolution-cache))
(in-package :cl-repository-client/constraint-builder)

(define-condition dependency-resolution-error (error)
  ((message :initarg :message :reader resolution-error-message))
  (:report (lambda (c s) (format s "Dependency resolution failed: ~a" (resolution-error-message c)))))

(define-condition system-lookup-error (error)
  ((name :initarg :name :reader system-lookup-error-name)
   (failures :initarg :failures :reader system-lookup-error-failures :initform nil
             :documentation "((registry-url . condition) ...), in registry order."))
  (:documentation
   "No registry answered that NAME is there, and at least one request failed
    (network, TLS, timeout, an HTTP 5xx, a broken pull). The package may well
    be in the registry: this is not \"not found\" (#120, #132).")
  (:report (lambda (c s)
             (format s "cl-repo: could not look up or pull ~a (not a missing package):~{~&  pulling ~a from ~a failed: ~a~}"
                     (system-lookup-error-name c)
                     (loop for (url . e) in (system-lookup-error-failures c)
                           collect (system-lookup-error-name c) collect url collect e)))))

;;; Caches for registry queries
;;;
;;; One cache serves a whole operation (a sync, an install, a test): sync
;;; resolves each missing top-level dependency on its own, and they share most
;;; of their transitive dependencies. WITH-RESOLUTION-CACHE opens the scope;
;;; a resolution outside one gets a cache of its own.

(defstruct (resolution-cache (:constructor make-resolution-cache ()))
  ;; package → version strings (unsorted, as listed)
  (versions (make-hash-table :test 'equal))
  ;; (package . version) → config, or :NONE when it could not be read
  (configs (make-hash-table :test 'equal))
  ;; (registry-url . repository) → tags (LIST-TAGS/RETRY answers)
  (tags (make-hash-table :test 'equal)))

(defvar *resolution-cache* nil
  "The RESOLUTION-CACHE of the operation in progress, or NIL.")

(defun call-with-resolution-cache (thunk)
  "Call THUNK with one registry cache for every resolution it makes. Nested
   calls share the outer cache."
  (if *resolution-cache*
      (funcall thunk)
      (let ((*resolution-cache* (make-resolution-cache)))
        (funcall thunk))))

(defmacro with-resolution-cache (() &body body)
  `(call-with-resolution-cache (lambda () ,@body)))

(defun cache-get (table key)
  (gethash key (funcall table *resolution-cache*)))

(defun cache-put (table key value)
  (setf (gethash key (funcall table *resolution-cache*)) value))

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

(defun installed-versions (name)
  "Version directories installed for system NAME."
  (let ((dir (merge-pathnames (format nil "~a/" name) (systems-root))))
    (mapcar (lambda (d) (car (last (pathname-directory d))))
            (ignore-errors (uiop:subdirectories dir)))))

(defun scan-installed-systems ()
  "Alist (name . version) of the locally installed systems: per system the
   version ASDF prefers (PREFERRED-INSTALL-TREES), the newest. It took the
   first version directory, usually the oldest, so cl-repo lock pinned
   repl-protocol 0.2.0 while 0.2.4 was installed."
  (let ((root (systems-root))
        (installed nil))
    (when (probe-file root)
      (dolist (sys-dir (uiop:subdirectories root))
        (let* ((name (car (last (pathname-directory sys-dir))))
               (versions (installed-versions name)))
          (when versions
            (push (cons name (select-preferred-version versions)) installed)))))
    (nreverse installed)))

;;; Registry queries (cached)

(defparameter *tag-list-attempts* 3
  "How many times LIST-TAGS/RETRY asks a registry before giving up.")

(defun %list-tags/retry (registry repo attempts lister)
  (loop for attempt from 1 to attempts
        do (handler-case (return (funcall lister registry repo))
             (registry-transport-error (e)
               (error e))
             (registry-error (e)
               (case (registry-error-status e)
                 (404 (return nil))
                 ((401 403)
                  (msg "~&; cl-repo: ~a: package not found in registry (~a)~%" repo e)
                  (return nil)))
               (msg "~&; cl-repo: ~a: tag listing failed (attempt ~d/~d): ~a~%"
                    repo attempt attempts e)
               (when (= attempt attempts) (error e)))
             (error (e)
               (msg "~&; cl-repo: ~a: tag listing failed (attempt ~d/~d): ~a~%"
                    repo attempt attempts e)
               (when (= attempt attempts) (error e))))
           (when (< attempt attempts) (sleep attempt))))

(defun list-tags/retry (registry repo &key (attempts *tag-list-attempts*)
                                           (lister #'list-tags))
  "LIST-TAGS with retries of failed answers (linear backoff 1s, 2s, ...).
   HTTP 404 (unknown repo) is final and yields NIL silently. HTTP 401/403 is
   final too (ghcr answers 403 at the token endpoint for an unknown repo when
   stored credentials are presented — one per sb-posix/uiop-style builtin) and
   is logged once as \"package not found in registry\". A request that got no
   response (REGISTRY-TRANSPORT-ERROR: HTTP-EXCHANGE already retried it)
   propagates at once. Any other error is logged per attempt and the last one
   is re-signalled: a failed lookup must not read as a missing package
   (#120, #132). LISTER is the tag-listing function (tests inject a stub).
   Inside WITH-RESOLUTION-CACHE, a listing that returned normally is kept for
   the rest of the operation: sync asks again for each package it installs."
  (if (and *resolution-cache* (eq lister #'list-tags))
      (let ((key (cons (cl-oci-client/registry:registry-url registry) repo)))
        (multiple-value-bind (tags found) (cache-get #'resolution-cache-tags key)
          (if found
              tags
              (let ((tags (%list-tags/retry registry repo attempts lister)))
                (cache-put #'resolution-cache-tags key tags)
                tags))))
      (%list-tags/retry registry repo attempts lister)))

(defun registry-repository (entry name)
  (format nil "~a/~a" (getf (rest entry) :namespace "cl-systems") (oci-package-name name)))

(defun registry-versions (name registries)
  "Version tags of NAME in REGISTRIES (already filtered by source policy).
   A registry whose lookup fails is skipped; when none has NAME and one
   failed, signals SYSTEM-LOOKUP-ERROR rather than answering \"no versions\"."
  (let ((versions nil)
        (failures nil))
    (dolist (entry registries)
      (let ((url (first entry)))
        (handler-case
            (dolist (tag (list-tags/retry (make-registry url)
                                          (registry-repository entry name)))
              (unless (string= tag "latest")
                (pushnew tag versions :test #'string=)))
          (error (e)
            (msg "~&; cl-repo: ~a: lookup in ~a failed: ~a~%" name url e)
            (push (cons url e) failures)))))
    (when (and failures (null versions))
      (error 'system-lookup-error :name name :failures (nreverse failures)))
    (nreverse versions)))


(defvar *version-lister* 'registry-versions
  "Function (name registries) → the version tags of NAME. Tests stub it.")

(defvar *config-fetcher* 'fetch-config-from-registry
  "Function (name version registries) → the CL-SYSTEM-CONFIG of NAME at
   VERSION, or NIL. Tests stub it.")

(defun allowed-registries (name registries)
  "REGISTRIES source policy lets NAME be looked up in."
  (when (oci-allowed-p name)
    (remove-if-not (lambda (entry) (registry-allowed-p name (first entry)))
                   registries)))

;;; Batched registry queries
;;;
;;; A level of the dependency graph is fetched at once: REGISTRY-REQUEST-BATCH
;;; keeps several requests in flight on one event loop. The batch only
;;; prefetches. Its answers seed the caches, and everything it could not
;;; answer goes through the one-at-a-time path, so failures are reported and
;;; retried exactly as before (#120, #132).

(defun prefetch-tag-lists (jobs)
  "JOBS: ((name . registries) ...). Lists the tags of every (registry,
   repository) not yet in the operation's cache in one batch and caches the
   answers LIST-TAGS/RETRY would have given: the tags, or NIL for a
   repository the registry does not have."
  (let ((todo nil))
    (loop for (name . regs) in jobs
          do (dolist (entry regs)
               (let ((key (cons (first entry) (registry-repository entry name))))
                 (unless (or (nth-value 1 (cache-get #'resolution-cache-tags key))
                             (member key todo :test #'equal))
                   (push key todo)))))
    (setf todo (nreverse todo))
    (when todo
      (loop for (url . repo) in todo
            for answer in (registry-request-batch
                           (mapcar (lambda (key)
                                     (list (make-registry (car key)) :get
                                           (format nil "/v2/~a/tags/list" (cdr key))))
                                   todo))
            do (cond
                 ((consp answer)
                  (let ((tags (ignore-errors (parse-tag-list (first answer)))))
                    (when (listp tags)
                      (cache-put #'resolution-cache-tags (cons url repo) tags))))
                 ((and (typep answer 'registry-error)
                       (not (typep answer 'registry-transport-error))
                       (eql 404 (registry-error-status answer)))
                  (cache-put #'resolution-cache-tags (cons url repo) nil)))))))
          ;; anything else: LIST-TAGS/RETRY asks again and reports it

(defun fetch-versions-batch (names registries)
  "Ensure the version lists of NAMES are cached."
  (let* ((todo (remove-duplicates
                (remove-if (lambda (name)
                             (or (implementation-system-p name)
                                 (nth-value 1 (cache-get #'resolution-cache-versions
                                                         (oci-package-name name)))))
                           names)
                :test #'string= :key #'oci-package-name))
         (jobs (mapcar (lambda (name) (cons name (allowed-registries name registries)))
                       todo)))
    (when (eq *version-lister* 'registry-versions)
      (prefetch-tag-lists jobs))
    (loop for (name . regs) in jobs
          do (cache-put #'resolution-cache-versions (oci-package-name name)
                        (and regs (funcall *version-lister* name regs))))))

(defun fetch-available-versions (name registries)
  "Get available versions for NAME from registries. Cached.
   Respects source policy: skips registries denied/not-allowed for NAME.
   Registry path uses OCI-PACKAGE-NAME (slash → primary, + → -plus-).
   A registry whose lookup fails is skipped; when none has NAME and one
   failed, signals SYSTEM-LOOKUP-ERROR rather than answering \"no versions\"."
  (unless (implementation-system-p name)
    (fetch-versions-batch (list name) registries)
    (values (cache-get #'resolution-cache-versions (oci-package-name name)))))

(defun parse-config-json (text)
  (from-json 'cl-system-config text))

(defun manifest-digest (registry repo tag)
  "The digest TAG of REPO points at, from a HEAD: no body."
  (multiple-value-bind (status headers) (head-manifest registry repo tag)
    (and status (= status 200) headers
         (gethash "docker-content-digest" headers))))

(defun manifest-config-digest (manifest)
  (format-digest (descriptor-digest (manifest-config manifest))))

(defun %octets (text) (babel:string-to-octets text :encoding :utf-8))

(defun %headers (&rest pairs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on pairs by #'cddr when v do (setf (gethash k h) v))
    h))

(defun use-stored-entry (registry url repo tag digest)
  "When TAG of REPO is stored at DIGEST, the config, after handing the
   stored manifests and config to *PULL-CACHE* for the install."
  (let ((entry (stored-entry url repo tag)))
    (when (and entry digest (equal digest (getf entry :digest)))
      (let ((config (ignore-errors (parse-config-json (getf entry :config)))))
        (when config
          (when (getf entry :index)
            (remember-pull registry repo tag
                           (list (%octets (getf entry :index)) 200
                                 (%headers "content-type" (getf entry :index-type)
                                           "docker-content-digest" digest))))
          (when (and (getf entry :manifest) (getf entry :manifest-digest))
            (remember-pull registry repo (getf entry :manifest-digest)
                           (list (%octets (getf entry :manifest)) 200
                                 (%headers "content-type" +oci-image-manifest-v1+
                                           "docker-content-digest" (getf entry :manifest-digest)))))
          (let ((manifest (ignore-errors
                           (parse-manifest-body (%octets (or (getf entry :manifest)
                                                             (getf entry :index)))
                                                (%headers "content-type" +oci-image-manifest-v1+)))))
            (when (typep manifest 'manifest)
              (remember-pull registry repo (manifest-config-digest manifest)
                             (list (%octets (getf entry :config)) 200 (%headers)))))
          config)))))

(defun store-chain (url repo tag digest tag-answer child-digest child-answer config-text)
  "Store what was read for TAG: its manifest or index (TAG-ANSWER), the
   index's manifest (CHILD-ANSWER at CHILD-DIGEST) and the config."
  (store-entry url repo tag
               (list :digest digest
                     :config config-text
                     :index (and tag-answer
                                 (ignore-errors (octets-to-string (first tag-answer) :encoding :utf-8)))
                     :index-type (and tag-answer (gethash "content-type" (third tag-answer)))
                     :manifest-digest child-digest
                     :manifest (and child-answer
                                    (ignore-errors (octets-to-string (first child-answer)
                                                                     :encoding :utf-8))))))

(defun fetch-config-at (registry url repo tag)
  "The config of REPO:TAG. A stored entry (CONFIG-STORE) is used when a HEAD
   of the tag answers the digest it was stored under; else the manifest (and
   index) and the config blob are pulled, and the entry stored."
  (when (stored-entry url repo tag)
    (let ((config (use-stored-entry registry url repo tag
                                    (ignore-errors (manifest-digest registry repo tag)))))
      (when config
        (return-from fetch-config-at config))))
  (let* ((tag-answer (multiple-value-list (pull-manifest-raw registry repo tag)))
         (digest (or (gethash "docker-content-digest" (third tag-answer))
                     (format-digest (compute-digest (first tag-answer)))))
         (obj (parse-manifest-body (first tag-answer) (third tag-answer)))
         (child-digest nil)
         (child-answer nil)
         (mfst (etypecase obj
                 (image-index
                  (let ((first-desc (first (image-index-manifests obj))))
                    (when first-desc
                      (setf child-digest (format-digest (descriptor-digest first-desc))
                            child-answer (multiple-value-list
                                          (pull-manifest-raw registry repo child-digest)))
                      (parse-manifest-body (first child-answer) (third child-answer)))))
                 (manifest obj))))
    (when (typep mfst 'manifest)
      (let* ((blob (pull-blob registry repo (manifest-config-digest mfst)))
             (text (octets-to-string blob :encoding :utf-8))
             (config (parse-config-json text)))
        (store-chain url repo tag digest tag-answer child-digest child-answer text)
        config))))

(defun fetch-config-from-registry (name version registries)
  "Actually fetch config from a registry."
  (dolist (entry registries nil)
    (let ((url (first entry)))
      (handler-case
          (let ((config (fetch-config-at (make-registry url) url
                                         (registry-repository entry name) version)))
            (when config (return config)))
        (error () nil)))))


(defstruct (config-job (:constructor make-config-job (name version url repo)))
  name version url repo
  (registry nil)
  (digest nil)                          ; of the tag's manifest or index
  (manifest nil)                        ; the manifest holding the config
  (tag-answer nil)                      ; (body status headers) of the tag
  (child-digest nil)                    ; of the index's manifest
  (child-answer nil)
  (config nil)
  (failed nil))

(defun %batch (jobs request-fn handle-fn)
  "Send (REQUEST-FN job) for each of JOBS that is still live, and call
   (HANDLE-FN job answer) with the answer. A failed request marks its job."
  (let ((live (remove-if (lambda (j) (or (config-job-failed j) (config-job-config j))) jobs)))
    (when live
      (loop for job in live
            for answer in (registry-request-batch (mapcar request-fn live))
            do (if (consp answer)
                   (unless (ignore-errors (funcall handle-fn job answer) t)
                     (setf (config-job-failed job) t))
                   (setf (config-job-failed job) t))))))

(defun prefetch-configs (pairs registries)
  "Configs of PAIRS ((name . version) ...) from the first registry, fetched
   stage by stage, each stage one batch: HEAD of the tags a config is stored
   for, the tags' manifests, index children, config blobs. Returns a list in
   the order of PAIRS: the config, or NIL where a request failed (the caller
   fetches those one at a time)."
  (let* ((entry (first registries))
         (url (first entry))
         (jobs (mapcar (lambda (pair)
                         (let ((job (make-config-job (car pair) (cdr pair) url
                                                     (registry-repository entry (car pair)))))
                           (setf (config-job-registry job) (make-registry url))
                           job))
                       pairs)))
    (flet ((manifest-path (job reference)
             (format nil "/v2/~a/manifests/~a" (config-job-repo job) reference))
           (take-manifest (job answer)
             (destructuring-bind (body status headers) answer
               (declare (ignore status))
               (unless (config-job-digest job)
                 (setf (config-job-digest job)
                       (or (gethash "docker-content-digest" headers)
                           (format-digest (compute-digest body)))))
               (let ((obj (parse-manifest-body body headers)))
                 (etypecase obj
                   (manifest (setf (config-job-manifest job) obj))
                   (image-index
                    (let ((first-desc (first (image-index-manifests obj))))
                      (if first-desc
                          ;; the child comes in the next stage
                          (setf (config-job-manifest job)
                                (format-digest (descriptor-digest first-desc)))
                          (setf (config-job-failed job) t)))))))))
      ;; 1. tags whose config is stored: does the tag still point there?
      (let ((stored (remove-if-not (lambda (j)
                                     (stored-entry url (config-job-repo j) (config-job-version j)))
                                   jobs)))
        (%batch stored
                (lambda (j) (list (config-job-registry j) :head
                                  (manifest-path j (config-job-version j))
                                  :accept *default-accept*))
                (lambda (j answer)
                  (let ((config (use-stored-entry (config-job-registry j) url
                                                  (config-job-repo j) (config-job-version j)
                                                  (gethash "docker-content-digest" (third answer)))))
                    (when config (setf (config-job-config j) config)))))
        ;; a HEAD that failed only means a GET is needed
        (dolist (j stored) (setf (config-job-failed j) nil)))
      ;; 2. the tags' manifests (or indexes)
      (%batch jobs
              (lambda (j) (list (config-job-registry j) :get
                                (manifest-path j (config-job-version j))
                                :accept *default-accept*))
              (lambda (j answer)
                (remember-pull (config-job-registry j) (config-job-repo j)
                               (config-job-version j) answer)
                (setf (config-job-tag-answer j) answer)
                (take-manifest j answer)))
      ;; 3. index children
      (%batch (remove-if-not (lambda (j) (stringp (config-job-manifest j))) jobs)
              (lambda (j) (list (config-job-registry j) :get
                                (manifest-path j (config-job-manifest j))
                                :accept *default-accept*))
              (lambda (j answer)
                (remember-pull (config-job-registry j) (config-job-repo j)
                               (config-job-manifest j) answer)
                (setf (config-job-child-digest j) (config-job-manifest j)
                      (config-job-child-answer j) answer
                      (config-job-manifest j) nil)
                (take-manifest j answer)
                (unless (typep (config-job-manifest j) 'manifest)
                  (setf (config-job-failed j) t))))
      ;; 4. config blobs
      (%batch (remove-if-not (lambda (j) (typep (config-job-manifest j) 'manifest)) jobs)
              (lambda (j) (list (config-job-registry j) :get
                                (format nil "/v2/~a/blobs/~a" (config-job-repo j)
                                        (manifest-config-digest (config-job-manifest j)))
                                :timeout (blob-timeout)))
              (lambda (j answer)
                (remember-pull (config-job-registry j) (config-job-repo j)
                               (manifest-config-digest (config-job-manifest j)) answer)
                (let* ((text (octets-to-string (first answer) :encoding :utf-8))
                       (config (parse-config-json text)))
                  (store-chain url (config-job-repo j) (config-job-version j)
                               (config-job-digest j) (config-job-tag-answer j)
                               (config-job-child-digest j) (config-job-child-answer j) text)
                  (setf (config-job-config j) config)))))
    (mapcar #'config-job-config jobs)))

(defun fetch-configs-batch (pairs registries)
  "Ensure the configs of PAIRS ((name . version) ...) are cached."
  (let* ((todo (remove-duplicates
                (remove-if (lambda (pair)
                             (nth-value 1 (cache-get #'resolution-cache-configs
                                                     (cons (oci-package-name (car pair))
                                                           (cdr pair)))))
                           pairs)
                :test #'equal))
         (prefetched (if (and (eq *config-fetcher* 'fetch-config-from-registry)
                              registries (cdr todo))
                         (prefetch-configs todo registries)
                         (make-list (length todo) :initial-element nil))))
    (loop for (name . version) in todo
          for config in prefetched
          do (cache-put #'resolution-cache-configs
                        (cons (oci-package-name name) version)
                        (or config
                            (funcall *config-fetcher* name version registries)
                            :none)))))

(defun fetch-config (name version registries)
  "Fetch config blob for NAME at VERSION. Cached."
  (fetch-configs-batch (list (cons name version)) registries)
  (let ((config (cache-get #'resolution-cache-configs (cons (oci-package-name name) version))))
    (unless (eq config :none) config)))

;;; Universe gathering, lazily and newest first
;;;
;;; The universe is name → list of (version . config-or-nil), newest first.
;;; Eagerly it held every published version of every reachable package, each
;;; config fetched one request at a time: minutes for a project with a deep
;;; tree of often-released packages. Now each package starts with one
;;; candidate, its newest acceptable version; only when the formula is
;;; unsatisfiable are older versions of the packages in the conflict added
;;; and the formula solved again. Every dependency constraint is a minimum,
;;; so the newest version satisfies whatever an older one does, and the
;;; widening is needed only around exact versions (the root's, the installed
;;; pins). A package's KNOWN versions (every version it has, or its pin)
;;; decide, as before, whether a constraint can be met at all.
;;;
;;; An installed package is pinned at its installed version only while that
;;; version meets every minimum asked of it. A dependent asking for more (a
;;; new cl-stack-snappy needing compression-protocol 0.4.0 over an installed
;;; 0.3.0) releases the pin: the package is looked up like any other and the
;;; plan upgrades it (#149). A minimum that no version meets, in the registry
;;; or in a copy ASDF finds, forbids the dependent version: resolution fails
;;; rather than plan an image that cannot load.

(defstruct (pkg-state (:constructor make-pkg-state (name known cands &optional pin)))
  name
  known                                 ; versions that exist, newest first
  cands                                 ; versions that may be loaded, newest first
  pin                                   ; the installed version it is held at, or NIL
  (entries nil))                        ; loaded (version . config), newest first

(defun newest-first (versions)
  (sort (copy-list versions) (lambda (a b) (version< b a))))

(defun version-satisfies-p (installed-version required-version)
  "Check if INSTALLED-VERSION satisfies REQUIRED-VERSION constraint.
   Uses asdf:version-satisfies when available, falls back to string>=."
  (handler-case
      (asdf:version-satisfies installed-version required-version)
    (error () (string>= installed-version required-version))))

(defun satisfying (versions constraint)
  (if constraint
      (remove-if-not (lambda (v) (version-satisfies-p v constraint)) versions)
      versions))

(defun entry-deps (entry)
  "Dependency specs of a universe ENTRY's config."
  (let ((config (cdr entry)))
    (and config (config-depends-on config))))

(defun universe-table (states)
  (let ((universe (make-hash-table :test 'equal)))
    (maphash (lambda (name state)
               (when (pkg-state-entries state)
                 (setf (gethash name universe) (pkg-state-entries state))))
             states)
    universe))

(defun package-floor (states name)
  "The lowest minimum version any loaded dependent asks of NAME: a version
   below it can satisfy no dependent. NIL when some dependent asks for any."
  (let ((floor nil) (seen nil))
    (block scan
      (maphash (lambda (dependent state)
                 (declare (ignore dependent))
                 (dolist (entry (pkg-state-entries state))
                   (dolist (dep (entry-deps entry))
                     (when (string= name (asdf-primary-system-name (dep-name dep)))
                       (let ((min (dep-version dep)))
                         (unless min
                           (setf floor nil seen t)
                           (return-from scan))
                         (when (or (not seen) (version< min floor))
                           (setf floor min seen t)))))))
               states))
    floor))

(defun unloaded-candidates (state &optional constraint)
  (let ((loaded (mapcar #'car (pkg-state-entries state))))
    (satisfying (remove-if (lambda (v) (member v loaded :test #'string=))
                           (pkg-state-cands state))
                constraint)))

(defun load-versions (plan registries)
  "Fetch the configs of PLAN ((state . versions) ...) and add them to the
   states' entries, keeping newest first. Returns the new entries."
  (fetch-configs-batch (loop for (state . versions) in plan
                             nconc (mapcar (lambda (v) (cons (pkg-state-name state) v))
                                           versions))
                       registries)
  (let ((added nil))
    (loop for (state . versions) in plan
          do (dolist (v versions)
               (let ((entry (cons v (fetch-config (pkg-state-name state) v registries))))
                 (push entry added)
                 (push entry (pkg-state-entries state))))
             (setf (pkg-state-entries state)
                   (sort (pkg-state-entries state)
                         (lambda (a b) (version< (car b) (car a))))))
    (nreverse added)))

(defun entry-dependency-requests (name entries)
  "(package . minimum) for every dependency of ENTRIES of package NAME.
   Signals DEPENDENCY-RESOLUTION-ERROR for a dependency source policy denies."
  (let ((requests nil))
    (dolist (entry entries (nreverse requests))
      (dolist (dep (entry-deps entry))
        (let ((dn (dep-name dep)))
          (when (system-denied-p dn)
            (error 'dependency-resolution-error
                   :message (format nil "~a depends on ~a which is denied by source policy"
                                    name dn)))
          (push (cons (asdf-primary-system-name dn) (dep-version dep)) requests))))))

(defun pin-meets-p (pin minimum)
  (or (null minimum) (version-satisfies-p pin minimum)))

(defun installed-pin (name requests installed force)
  "The installed version of NAME to hold it at: it meets every minimum
   REQUESTS ((name . minimum) ...) ask of NAME. NIL when FORCE, when NAME is
   not installed, or when a request asks for more."
  (let ((pin (and (not force) (cdr (assoc name installed :test #'string=)))))
    (and pin
         (every (lambda (r)
                  (or (string/= name (car r)) (pin-meets-p pin (cdr r))))
                requests)
         pin)))

(defun outgrown-pins (states requests)
  "((state . minimum) ...): the pinned states of STATES that a request in
   REQUESTS asks more of than the pin, each once, with its highest minimum."
  (let ((out nil))
    (dolist (r requests (nreverse out))
      (let ((state (gethash (car r) states)))
        (when (and state (pkg-state-pin state)
                   (not (pin-meets-p (pkg-state-pin state) (cdr r))))
          (let ((old (assoc state out)))
            (cond ((null old) (push (cons state (cdr r)) out))
                  ((version< (cdr old) (cdr r)) (setf (cdr old) (cdr r))))))))))

(defun release-pin (state minimum registries)
  "Let STATE, pinned at its installed version, take any version: KNOWN
   becomes every version the registries have (and the installed one).
   Returns the versions to load: the newest that meets MINIMUM, or none."
  (let* ((pin (pkg-state-pin state))
         (known (newest-first
                 (adjoin pin (fetch-available-versions (pkg-state-name state) registries)
                         :test #'string=))))
    (msg "~&; cl-repo: installed ~a ~a is below the ~a a dependent needs; resolving it again~%"
         (pkg-state-name state) pin minimum)
    (setf (pkg-state-pin state) nil
          (pkg-state-known state) known
          (pkg-state-cands state) known)
    (let ((newest (first (unloaded-candidates state minimum))))
      (and newest (list newest)))))

(defun expand-universe (states requests registries installed force)
  "Add the packages of REQUESTS ((name . minimum) ...) and everything they
   reach to STATES, one candidate each, level by level: the version lists of
   a level are fetched in one batch, then the configs of their candidates.
   A request asking more of a pinned package than its installed version
   releases the pin (RELEASE-PIN)."
  (loop while requests
        do (let ((outgrown (outgrown-pins states requests))
                 (fresh (remove-duplicates
                         (remove-if (lambda (r) (gethash (car r) states)) requests)
                         :key #'car :test #'string= :from-end t))
                 (level requests))
             (setf requests nil)
             (fetch-versions-batch
              (nconc (mapcar (lambda (o) (pkg-state-name (car o))) outgrown)
                     (loop for (name) in fresh
                           unless (installed-pin name level installed force)
                             collect name))
              registries)
             (let ((plan nil))
               (loop for (state . minimum) in outgrown
                     do (let ((versions (release-pin state minimum registries)))
                          (when versions (push (cons state versions) plan))))
               (loop for (name . minimum) in fresh
                     do (let* ((pinned (installed-pin name level installed force))
                               (versions (cond (pinned (list pinned))
                                               ((fetch-available-versions name registries))
                                               (minimum (list minimum))))
                               (known (newest-first versions)))
                          (when known
                            (let ((state (make-pkg-state name known known pinned)))
                              (setf (gethash name states) state)
                              ;; the newest that meets this first request; the
                              ;; newest of all when none does
                              (push (cons state
                                          (list (or (first (satisfying known minimum))
                                                    (first known))))
                                    plan)))))
               (dolist (entry-group (group-by-state (load-versions (nreverse plan) registries)
                                                    states))
                 (setf requests (nconc requests
                                       (entry-dependency-requests (car entry-group)
                                                                  (cdr entry-group))))))))
  states)

(defun group-by-state (entries states)
  "((name . entries) ...) for ENTRIES, which are entries of STATES."
  (let ((groups nil))
    (maphash (lambda (name state)
               (let ((mine (remove-if-not (lambda (e) (member e (pkg-state-entries state) :test #'eq))
                                          entries)))
                 (when mine (push (cons name mine) groups))))
             states)
    (sort groups #'string< :key #'car)))

(defun blocked-requirements (states)
  "(dependent-state . (target-state . minimum)) for each loaded version whose
   dependency some known version meets but no loaded version does: the
   clause forbids that version until the target or the dependent widens."
  (let ((blocked nil))
    (maphash
     (lambda (name state)
       (declare (ignore name))
       (dolist (entry (pkg-state-entries state))
         (dolist (dep (entry-deps entry))
           (let* ((target (gethash (asdf-primary-system-name (dep-name dep)) states))
                  (min (dep-version dep)))
             (when (and target
                        (satisfying (pkg-state-known target) min)
                        (null (satisfying (mapcar #'car (pkg-state-entries target)) min)))
               (push (cons state (cons target min)) blocked))))))
     states)
    blocked))

(defun widening-plan (states)
  "Which older versions to load after an unsatisfiable solve: for each
   blocked requirement, the target's versions that meet it and the
   dependent's next older versions, twice as many as are loaded. NIL when
   nothing can be added: the conflict is real."
  (let ((plan nil))
    (flet ((add (state versions)
             (let ((n (max 1 (length (pkg-state-entries state))))
                   (old (assoc state plan)))
               (when versions
                 (let ((take (subseq versions 0 (min n (length versions)))))
                   (if old
                       (setf (cdr old) (union (cdr old) take :test #'string=))
                       (push (cons state take) plan)))))))
      (dolist (b (blocked-requirements states))
        (destructuring-bind (dependent target . min) b
          (add target (unloaded-candidates target min))
          (add dependent (unloaded-candidates
                          dependent (package-floor states (pkg-state-name dependent))))))
      ;; Nothing identifiable: widen every package that can be.
      (unless plan
        (maphash (lambda (name state)
                   (add state (unloaded-candidates state (package-floor states name))))
                 states)))
    (mapcar (lambda (p) (cons (car p) (newest-first (cdr p))))
            (sort plan #'string< :key (lambda (p) (pkg-state-name (car p)))))))

(defun reachable-solution (root-name solution universe)
  "Package names reachable from ROOT-NAME through the versions SOLUTION
   chose. A package reached only through versions it did not choose stays out
   of the plan."
  (let ((chosen (make-hash-table :test 'equal))
        (reached (make-hash-table :test 'equal))
        (queue (list root-name)))
    (dolist (binding solution)
      (when (cdr binding)
        (let ((parsed (parse-pkg-var (car binding))))
          (when parsed (push (cdr parsed) (gethash (car parsed) chosen))))))
    (loop while queue
          do (let ((name (pop queue)))
               (unless (gethash name reached)
                 (setf (gethash name reached) t)
                 (dolist (entry (gethash name universe))
                   (when (member (car entry) (gethash name chosen) :test #'string=)
                     (dolist (dep (entry-deps entry))
                       (push (asdf-primary-system-name (dep-name dep)) queue)))))))
    reached))

;;; Eager universe: every version of every reachable package. Kept as the
;;; reference the lazy resolution is tested against.

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
                    (when config
                      (dolist (dep (config-depends-on config))
                        (let* ((dn (dep-name dep))
                               (pkg (asdf-primary-system-name dn)))
                          (when (system-denied-p dn)
                            (error 'dependency-resolution-error
                                   :message (format nil "~a depends on ~a which is denied by source policy"
                                                    name dn)))
                          (unless (gethash pkg universe)
                            (push (cons pkg (dep-version dep)) queue)))))))
                (setf (gethash name universe) (nreverse entries))))))))
    universe))

;;; Formula building

(defvar *unmet-minimums* nil
  "((dependent version dependency minimum) ...) seen by LOCALLY-MET-P in this
   resolution: a minimum no known version meets, nor a copy ASDF finds.")

(defun locally-met-p (name minimum)
  "True when MINIMUM of NAME, which no version in the registries meets, is met
   by a copy ASDF finds that a fresh image loads too (SYSTEM-SATISFIED-P): an
   unpublished checkout on the source registry. Only then is the requirement
   left to ASDF; otherwise it forbids the dependent version (#149)."
  (or (null minimum)
      (ignore-errors (system-satisfied-p name minimum))))


(defun build-formula (root-name root-version universe installed &key force known)
  "Build SAT formula from the package universe.
   KNOWN: function of a package name → the versions it has, which decide
   whether a constraint can be met at all; default its universe versions."
  (let ((terms nil))
    ;; Root must be true
    (push (sat-var (pkg-var root-name root-version)) terms)
    ;; Pin installed systems (INSTALLED: the pins that hold)
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
                 (let* ((dn (asdf-primary-system-name (dep-name dep)))
                        (dv (dep-version dep))
                        (dep-entries (gethash dn universe)))
                   (when (and dep-entries
                              (or (satisfying (if known
                                                  (funcall known dn)
                                                  (mapcar #'car dep-entries))
                                              dv)
                                  (and (not (locally-met-p dn dv))
                                       ;; No version meets DV anywhere: the
                                       ;; OR is empty and forbids ENTRY-VAR.
                                       (pushnew (list name ver dn dv) *unmet-minimums*
                                                :test #'equal))))
                     (push (sat-imply (sat-var entry-var)
                                      (sat-or (mapcar #'sat-var
                                                      (matching-versions dep-entries dn dv))))
                           terms)))))))))
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

;;; Missing dependency detection

(defun find-missing-deps (universe &optional reached)
  "Return list of dep names referenced in configs but absent from UNIVERSE and ASDF.
   REACHED (a table of package names) limits the configs looked at."
  (let ((missing nil))
    (maphash (lambda (name entries)
               (when (or (null reached) (gethash name reached))
                 (dolist (entry entries)
                   (let ((config (cdr entry)))
                     (when config
                       (dolist (dep (config-depends-on config))
                         (let* ((dn (dep-name dep))
                                (pkg (asdf-primary-system-name dn)))
                           (unless (or (gethash pkg universe)
                                       (implementation-system-p dn)
                                       (implementation-system-p pkg)
                                       (asdf:find-system dn nil)
                                       (asdf:find-system pkg nil))
                             (pushnew dn missing :test #'string=)))))))))
             universe)
    missing))

;;; Main entry point

(defun held-pins (root-name root-pin installed states)
  "The pairs of INSTALLED still held at their installed version: the root's
   ROOT-PIN, and each package whose pin no dependent outgrew."
  (loop for pair in installed
        for (name . version) = pair
        for state = (gethash name states)
        when (if (string= name root-name)
                 (equal version root-pin)
                 (and state (equal version (pkg-state-pin state))))
          collect pair))

(defun solve-lazily (root-name root-version registries installed force)
  "Solve newest first, widening around conflicts. Returns
   (values solution universe), SOLUTION NIL when unsatisfiable."
  (let* ((states (make-hash-table :test 'equal))
         (installed-root (and (not force) (cdr (assoc root-name installed :test #'string=))))
         ;; An installed root is kept only at the version asked for: a
         ;; caller re-resolves an installed root because it is too old.
         (pinned (and installed-root (string= installed-root root-version) installed-root)))
    ;; The root is wanted at ROOT-VERSION exactly; its other versions only
    ;; tell a dependent asking for more that it can exist, which forbids that
    ;; dependent's version.
    (let* ((known (newest-first
                   (if pinned
                       (list pinned)
                       (adjoin root-version (fetch-available-versions root-name registries)
                               :test #'string=))))
           (state (make-pkg-state root-name known (list (or pinned root-version)))))
      (setf (gethash root-name states) state)
      (expand-universe states
                       (entry-dependency-requests
                        root-name (load-versions (list (list state (or pinned root-version)))
                                                 registries))
                       registries installed force))
    (loop
      (let* ((universe (universe-table states))
             (solution (sat-solve
                        (build-formula root-name root-version universe
                                       (held-pins root-name pinned installed states)
                                       :force force
                                       :known (lambda (name)
                                                (let ((s (gethash name states)))
                                                  (and s (pkg-state-known s))))))))
        (when solution
          (return (values solution universe)))
        (let ((plan (widening-plan states)))
          (unless plan
            (return (values nil universe)))
          (let ((added (load-versions plan registries)))
            (expand-universe states
                             (loop for (name . entries) in (group-by-state added states)
                                   nconc (entry-dependency-requests name entries))
                             registries installed force)))))))

(defun build-install-plan (root-name root-version registries &key force)
  "Build a complete install plan for ROOT-NAME.
   ROOT-VERSION: specific version string or :latest (auto-discover).
   Returns (values plan missing-deps) where plan is alist ((name . version) ...)
   and missing-deps is a list of dep names not found in any registry or ASDF.
   Signals dependency-resolution-error on failure.
   Registry answers are cached for the enclosing WITH-RESOLUTION-CACHE."
  (with-resolution-cache ()
    (ensure-http-backend)
    (setf root-name (asdf-primary-system-name root-name))
    ;; Resolve :latest to actual version
    (when (or (eq root-version :latest) (null root-version))
      (let ((versions (fetch-available-versions root-name registries)))
        (unless versions
          (error 'dependency-resolution-error
                 :message (format nil "~a not found in any registry" root-name)))
        (setf root-version (select-preferred-version versions))))
    (let ((installed (scan-installed-systems))
          (*unmet-minimums* nil))
      (multiple-value-bind (solution universe)
          (solve-lazily root-name root-version registries installed force)
        (unless solution
          (error 'dependency-resolution-error
                 :message (format nil "Cannot satisfy dependencies for ~a ~a~:[~; (conflicts with installed systems; try :force t)~]~:{; ~a ~a needs ~a ~a, which no registry has~}"
                                  root-name root-version (and (not force) installed t)
                                  (reverse *unmet-minimums*))))
        (let ((reached (reachable-solution root-name solution universe))
              (plan nil))
          ;; Extract install plan: true bindings, except versions installed
          ;; (an installed package a dependent outgrew is planned at its
          ;; new version)
          (dolist (binding solution)
            (when (cdr binding)
              (let ((parsed (parse-pkg-var (car binding))))
                (when parsed
                  (let ((name (car parsed))
                        (version (cdr parsed)))
                    (unless (or (not (gethash name reached))
                                (and (not force)
                                     (member version (installed-versions name)
                                             :test #'string=)))
                      (push (cons name version) plan)))))))
          (values (nreverse plan) (find-missing-deps universe reached)))))))
