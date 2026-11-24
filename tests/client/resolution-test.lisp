(defpackage :cl-repository-client/tests/resolution-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/constraint-builder
                #:build-install-plan #:dependency-resolution-error
                #:system-lookup-error #:with-resolution-cache #:list-tags/retry)
  (:import-from :cl-oci/config #:cl-system-config)
  (:import-from :cl-oci-client/registry #:make-registry)
  (:import-from :bordeaux-threads #:make-lock #:with-lock-held))
(in-package :cl-repository-client/tests/resolution-test)

;;; A fake registry: SPEC is ((name (version dep...) ...) ...), each dep a
;;; name or (name . minimum). Counts every version listing and config fetch.

(defvar *registries* '(("https://fake.test" :namespace "ns")))

(defstruct fake spec (lock (make-lock)) (listings nil) (fetches nil))

(defun fake-package (fake name)
  (cdr (assoc name (fake-spec fake) :test #'string=)))

(defun fake-config (name version deps)
  (make-instance 'cl-system-config :system-name name :version version :depends-on deps))

(defun count-of (name calls)
  (count name calls :key (lambda (c) (if (consp c) (car c) c)) :test #'string=))

(defun fetched-p (fake name version)
  (member (cons name version) (fake-fetches fake) :test #'equal))

(defun call-with-fake (spec thunk &key installed (jobs "8"))
  "Call THUNK with the fake registry for SPEC and an install tree holding
   INSTALLED ((name . version) ...)."
  (let* ((fake (make-fake :spec spec))
         (root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-res-~36r/" (uiop:temporary-directory)
                        (random (expt 36 8) (make-random-state t)))))
         (old-jobs (uiop:getenv "CL_REPO_FETCH_JOBS")))
    (dolist (pair installed)
      (ensure-directories-exist (merge-pathnames (format nil "~a/~a/" (car pair) (cdr pair)) root)))
    (ensure-directories-exist root)
    (unwind-protect
         (let ((cl-repository-client/installer::*systems-root* root)
               (cl-repository-client/constraint-builder::*resolution-cache* nil)
               (cl-repository-client/constraint-builder::*version-lister*
                 (lambda (name registries)
                   (declare (ignore registries))
                   (with-lock-held ((fake-lock fake)) (push name (fake-listings fake)))
                   (mapcar #'car (fake-package fake name))))
               (cl-repository-client/constraint-builder::*config-fetcher*
                 (lambda (name version registries)
                   (declare (ignore registries))
                   (with-lock-held ((fake-lock fake))
                     (push (cons name version) (fake-fetches fake)))
                   (let ((entry (assoc version (fake-package fake name) :test #'string=)))
                     (and entry (fake-config name version (cdr entry))))))
               (cl-oci/runtime:*quiet* t))
           (setf (uiop:getenv "CL_REPO_FETCH_JOBS") jobs)
           (funcall thunk fake))
      (setf (uiop:getenv "CL_REPO_FETCH_JOBS") (or old-jobs ""))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(defmacro with-fake ((fake spec &rest keys) &body body)
  `(call-with-fake ,spec (lambda (,fake) (declare (ignorable ,fake)) ,@body) ,@keys))

(defun plan (root &optional (version :latest))
  (sort (copy-list (build-install-plan root version *registries*)) #'string< :key #'car))

(defun eager-plan (root version)
  "The plan the eager resolution (every version of every reachable package)
   makes, for comparison."
  (with-resolution-cache ()
    (let* ((cb "CL-REPOSITORY-CLIENT/CONSTRAINT-BUILDER")
           (installed (uiop:symbol-call cb "SCAN-INSTALLED-SYSTEMS"))
           (universe (uiop:symbol-call cb "GATHER-UNIVERSE" root version *registries* installed))
           (solution (cl-repository-client/solver:sat-solve
                      (uiop:symbol-call cb "BUILD-FORMULA" root version universe installed))))
      (and solution
           (sort (loop for (var . value) in solution
                       for parsed = (uiop:symbol-call cb "PARSE-PKG-VAR" var)
                       when (and value parsed
                                 (not (assoc (car parsed) installed :test #'string=)))
                         collect parsed)
                 #'string< :key #'car)))))

(defun versions (from to)
  (loop for i from from to to collect (format nil "~d.0" i)))

;;; Fetch counts

(deftest implementation-systems-never-enter-the-plan
  "#171: dexador's (:version \"uiop\" \"3.1.1\") put uiop 3.1.1 in the plan, and
   the install pulled a package no registry has (GHCR: 403). uiop, asdf and
   SBCL contribs ship with the Lisp: never listed, fetched or planned."
  (with-fake (fake '(("app" ("1.0" ("uiop" . "3.1.1") ("asdf" . "3.3") "uiop" "lib"))
                     ("lib" ("1.0" ("uiop" . "3.1.1") "sb-posix"))))
    (ok (equal '(("app" . "1.0") ("lib" . "1.0")) (plan "app"))
        "only the packages the registries have")
    (dolist (name '("uiop" "asdf"))
      (ok (zerop (count-of name (fake-listings fake))) (format nil "~a never listed" name))
      (ok (zerop (count-of name (fake-fetches fake))) (format nil "~a never fetched" name)))))

(deftest newest-version-that-satisfies-is-the-only-config-fetched
  "A package with 50 versions whose newest satisfies: one config, not 50."
  (with-fake (fake `(("app" ("1.0" ("many" . "3.0")))
                     ("many" ,@(mapcar #'list (versions 1 50)))))
    (ok (equal '(("app" . "1.0") ("many" . "50.0")) (plan "app")))
    (ok (= 1 (count-of "many" (fake-fetches fake))) "one config of many")
    (ok (= 1 (count-of "many" (fake-listings fake))) "one listing of many")))

(deftest older-version-is-found-when-the-newest-conflicts
  "app 1.0 is wanted exactly; lib 5.0 and 4.0 need app 2.0: lib 3.0."
  (let ((spec '(("app" ("1.0" "lib") ("2.0" "lib"))
                ("lib" ("1.0" ("app" . "1.0")) ("2.0" ("app" . "1.0")) ("3.0" ("app" . "1.0"))
                 ("4.0" ("app" . "2.0")) ("5.0" ("app" . "2.0"))))))
    (with-fake (fake spec)
      (ok (equal '(("app" . "1.0") ("lib" . "3.0")) (plan "app" "1.0")))
      (ok (not (fetched-p fake "lib" "1.0")) "nothing older than needed"))
    (with-fake (fake spec)
      (ok (equal (eager-plan "app" "1.0") (plan "app" "1.0")) "same as eager"))))

(deftest versions-below-the-minimum-are-never-fetched
  "app needs lib 3.0; lib 5.0 and 4.0 need app 2.0. Widening stops at the
   minimum: lib 2.0 and 1.0 cannot satisfy app and are not fetched."
  (with-fake (fake '(("app" ("1.0" ("lib" . "3.0")) ("2.0" ("lib" . "3.0")))
                     ("lib" ("1.0") ("2.0") ("3.0" ("app" . "1.0"))
                      ("4.0" ("app" . "2.0")) ("5.0" ("app" . "2.0")))))
    (ok (equal '(("app" . "1.0") ("lib" . "3.0")) (plan "app" "1.0")))
    (ok (not (fetched-p fake "lib" "2.0")))
    (ok (not (fetched-p fake "lib" "1.0")))))

(deftest exact-root-version-is-the-only-root-config-fetched
  (with-fake (fake `(("app" ,@(mapcar #'list (versions 1 20)))))
    (ok (equal '(("app" . "7.0")) (plan "app" "7.0")))
    (ok (equal '(("app" . "7.0")) (fake-fetches fake)))))

(deftest unsatisfiable-reports-the-same-error
  "Every lib needs app 2.0 and app 1.0 is wanted exactly: no plan, after
   every candidate was tried."
  (let ((spec '(("app" ("1.0" "lib") ("2.0" "lib"))
                ("lib" ("1.0" ("app" . "2.0")) ("2.0" ("app" . "2.0")) ("3.0" ("app" . "2.0"))))))
    (with-fake (fake spec)
      (ok (null (eager-plan "app" "1.0")) "eager finds no plan either"))
    (with-fake (fake spec)
      (let ((e (handler-case (progn (plan "app" "1.0") nil)
                 (dependency-resolution-error (e) e))))
        (ok e)
        (ok (search "Cannot satisfy dependencies for app 1.0" (princ-to-string e))))
      (ok (fetched-p fake "lib" "1.0") "all candidates tried"))))

(deftest lazy-matches-eager-on-a-tree
  (let ((spec '(("app" ("1.0" "a" ("b" . "1.1")) ("0.9" "a"))
                ("a" ("1.0" "c") ("1.1" "c" ("d" . "2.0")))
                ("b" ("1.0") ("1.1" "d") ("1.2" ("d" . "1.0")))
                ("c" ("0.1") ("0.2"))
                ("d" ("1.0") ("2.0") ("2.1" "c")))))
    (let (lazy eager)
      (with-fake (fake spec) (setf lazy (plan "app")))
      (with-fake (fake spec) (setf eager (eager-plan "app" "1.0")))
      (ok (equal eager lazy))
      (ok (equal '(("a" . "1.1") ("app" . "1.0") ("b" . "1.2") ("c" . "0.2") ("d" . "2.1"))
                 lazy)))))

(deftest installed-pins-are-kept
  (with-fake (fake '(("app" ("1.0" ("lib" . "1.0")))
                     ("lib" ("1.0") ("2.0") ("3.0")))
                   :installed '(("lib" . "2.0")))
    (ok (equal '(("app" . "1.0")) (plan "app")))
    (ok (not (fetched-p fake "lib" "3.0")) "a pinned package is not looked up")))

;;; An installed pin gives way to a dependent's minimum (#149). Names are
;;; unlikely to be findable through ASDF here: LOCALLY-MET-P asks it.

(deftest installed-pin-is-released-for-a-new-transitive-minimum
  "Installed x149 0.3.0; app149 → a149 (new) → x149 >= 0.4.0: the plan
   upgrades x149 to 0.4.0."
  (with-fake (fake '(("app149" ("1.0" "a149"))
                     ("a149" ("1.0" ("x149" . "0.4.0")))
                     ("x149" ("0.3.0") ("0.4.0")))
                   :installed '(("x149" . "0.3.0")))
    (ok (equal '(("a149" . "1.0") ("app149" . "1.0") ("x149" . "0.4.0")) (plan "app149")))))

(deftest installed-pin-is-released-for-a-direct-minimum
  (with-fake (fake '(("app149" ("1.0" ("x149" . "0.4.0")))
                     ("x149" ("0.3.0") ("0.4.0") ("0.5.0")))
                   :installed '(("x149" . "0.3.0")))
    (ok (equal '(("app149" . "1.0") ("x149" . "0.5.0")) (plan "app149")))))

(deftest installed-pin-is-released-when-a-later-dependent-outgrows-it
  "x149 is pinned when first reached (a149 asks for any), then b149 a level
   down asks for 0.4.0."
  (with-fake (fake '(("app149" ("1.0" "a149" "c149"))
                     ("a149" ("1.0" "x149"))
                     ("c149" ("1.0" "b149"))
                     ("b149" ("1.0" ("x149" . "0.4.0")))
                     ("x149" ("0.3.0") ("0.4.0")))
                   :installed '(("x149" . "0.3.0")))
    (ok (equal '(("a149" . "1.0") ("app149" . "1.0") ("b149" . "1.0") ("c149" . "1.0")
                 ("x149" . "0.4.0"))
               (plan "app149")))))

(deftest installed-root-below-the-newest-is-planned
  "A root re-resolved because its install is too old is planned at the
   newest version, not kept at the installed one."
  (with-fake (fake '(("x149" ("0.3.0") ("0.4.0")))
                   :installed '(("x149" . "0.3.0")))
    (ok (equal '(("x149" . "0.4.0")) (plan "x149")))))

(deftest unmet-minimum-of-an-installed-package-fails
  "Installed x149 0.3.0, and no version meets a149's 0.4.0: resolution
   fails, naming the requirement, instead of planning an image that cannot
   load."
  (with-fake (fake '(("app149" ("1.0" "a149"))
                     ("a149" ("1.0" ("x149" . "0.4.0")))
                     ("x149" ("0.2.0") ("0.3.0")))
                   :installed '(("x149" . "0.3.0")))
    (let ((e (handler-case (progn (plan "app149") nil)
               (dependency-resolution-error (e) e))))
      (ok e "signals DEPENDENCY-RESOLUTION-ERROR")
      (ok (and e (search "a149 1.0 needs x149 0.4.0" (princ-to-string e)))
          "names the unmet minimum"))))

(deftest unmet-minimum-picks-an-older-dependent-that-fits
  "a149 2.0 needs x149 0.9.0, which no registry has; a149 1.0 fits."
  (with-fake (fake '(("app149" ("1.0" "a149"))
                     ("a149" ("1.0" "x149") ("2.0" ("x149" . "0.9.0")))
                     ("x149" ("0.3.0") ("0.4.0"))))
    (ok (equal '(("a149" . "1.0") ("app149" . "1.0") ("x149" . "0.4.0")) (plan "app149")))))

;;; One cache per operation

(deftest cache-is-shared-across-top-level-dependencies
  "sync resolves each missing top-level dependency on its own; their shared
   dependencies are listed and fetched once."
  (with-fake (fake '(("one" ("1.0" "shared")) ("two" ("1.0" "shared"))
                     ("shared" ("1.0" "leaf") ("2.0" "leaf")) ("leaf" ("1.0"))))
    (with-resolution-cache ()
      (ok (equal '(("leaf" . "1.0") ("one" . "1.0") ("shared" . "2.0")) (plan "one")))
      (ok (equal '(("leaf" . "1.0") ("shared" . "2.0") ("two" . "1.0")) (plan "two"))))
    (ok (= 1 (count-of "shared" (fake-fetches fake))))
    (ok (= 1 (count-of "leaf" (fake-fetches fake))))
    (ok (= 1 (count-of "shared" (fake-listings fake))))))

(deftest without-an-operation-each-resolution-has-its-own-cache
  (with-fake (fake '(("one" ("1.0" "shared")) ("shared" ("1.0"))))
    (plan "one")
    (plan "one")
    (ok (= 2 (count-of "shared" (fake-fetches fake))))))

;;; Parallel fetches

(deftest one-and-eight-jobs-agree
  (let ((spec `(("app" ("1.0" ,@(loop for i from 1 to 12 collect (format nil "p~d" i))))
                ,@(loop for i from 1 to 12
                        collect `(,(format nil "p~d" i)
                                  ,@(mapcar (lambda (v) (list v "leaf")) (versions 1 4))))
                ("leaf" ("1.0") ("2.0")))))
    (let (one many)
      (with-fake (fake spec :jobs "1") (setf one (plan "app")))
      (with-fake (fake spec :jobs "8") (setf many (plan "app")))
      (ok (equal one many))
      (ok (= 14 (length many))))))

(deftest lookup-failures-propagate-from-batched-fetches
  "A failed lookup in a batch of lookups is signalled to the caller, not taken as
   \"no versions\" (#120, #132)."
  (with-fake (fake '(("app" ("1.0" "a" "b" "c")) ("a" ("1.0")) ("b" ("1.0")) ("c" ("1.0"))))
    (let ((cl-repository-client/constraint-builder::*version-lister*
            (let ((inner cl-repository-client/constraint-builder::*version-lister*))
              (lambda (name registries)
                (if (string= name "b")
                    (error 'system-lookup-error :name "b" :failures nil)
                    (funcall inner name registries))))))
      (ok (signals (plan "app") 'system-lookup-error)))))

(deftest tag-listings-are-kept-for-the-operation
  "LIST-TAGS/RETRY answers once per operation: sync asks again for each
   package it installs."
  (let* ((sym 'cl-oci-client/content-discovery:list-tags)
         (orig (fdefinition sym))
         (calls 0))
    (unwind-protect
         (progn
           (setf (fdefinition sym)
                 (lambda (registry repo &rest args)
                   (declare (ignore registry repo args))
                   (incf calls)
                   (list "1.0" "2.0")))
           (let ((reg (make-registry "https://fake.test")))
             (with-resolution-cache ()
               (ok (equal '("1.0" "2.0") (list-tags/retry reg "ns/x")))
               (ok (equal '("1.0" "2.0") (list-tags/retry reg "ns/x"))))
             (ok (= 1 calls) "once inside the operation")
             (list-tags/retry reg "ns/x")
             (ok (= 2 calls) "not cached outside one")))
      (setf (fdefinition sym) orig))))

;;; Configs on disk

(deftest stored-configs-are-keyed-by-tag-and-digest
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-cfg-~36r/" (uiop:temporary-directory)
                       (random (expt 36 8) (make-random-state t)))))
         (old (uiop:getenv "CL_REPO_CONFIG_CACHE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") (uiop:native-namestring dir))
           (ok (null (cl-repository-client/config-store:stored-config "https://r" "ns/a" "1.0")))
           (ok (cl-repository-client/config-store:store-config
                "https://r" "ns/a" "1.0" "sha256:abc" "{\"name\": \"a\"}"))
           (multiple-value-bind (digest text)
               (cl-repository-client/config-store:stored-config "https://r" "ns/a" "1.0")
             (ok (equal "sha256:abc" digest))
             (ok (search "\"a\"" text)))
           (ok (null (cl-repository-client/config-store:stored-config "https://r" "ns/a" "2.0")))
           (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") "off")
           (ok (null (cl-repository-client/config-store:config-store-directory))))
      (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") (or old ""))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

;;; The batched config fetch, over a scripted registry

(defun %digest (text)
  (cl-oci/digest:format-digest (cl-oci/digest:compute-digest text)))

(defun %octets (text) (babel:string-to-octets text :encoding :utf-8))

(defun %headers (&rest pairs)
  (let ((h (make-hash-table :test #'equal)))
    (loop for (k v) on pairs by #'cddr do (setf (gethash k h) v))
    h))

(defun scripted-package (name version &optional (deps '("alexandria")))
  "An index → manifest → config blob chain for NAME VERSION:
   (values index-text routes), ROUTES ((path . answer) ...)."
  (let* ((config (cl-oci/serialization:to-json
                  (fake-config name version deps)))
         (manifest (format nil "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/vnd.cl-system.config.v1+json\",\"digest\":\"~a\",\"size\":~d},\"layers\":[]}"
                           (%digest config) (length config)))
         (index (format nil "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"manifests\":[{\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"digest\":\"~a\",\"size\":~d}]}"
                        (%digest manifest) (length manifest)))
         (repo (format nil "ns/~a" name)))
    (values index
            (list (cons (format nil "/v2/~a/manifests/~a" repo version)
                        (list (%octets index) 200
                              (%headers "content-type" "application/vnd.oci.image.index.v1+json"
                                        "docker-content-digest" (%digest index))))
                  (cons (format nil "/v2/~a/manifests/~a" repo (%digest manifest))
                        (list (%octets manifest) 200
                              (%headers "content-type" "application/vnd.oci.image.manifest.v1+json")))
                  (cons (format nil "/v2/~a/blobs/~a" repo (%digest config))
                        (list (%octets config) 200 (%headers)))))))

(deftest batched-config-fetch-follows-index-manifest-blob-and-stores-it
  (let* ((routes (append (nth-value 1 (scripted-package "a" "1.0"))
                         (nth-value 1 (scripted-package "b" "2.0"))))
         (sent '())
         (sym 'cl-oci-client/registry:registry-request-batch)
         (orig (fdefinition sym))
         (dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-cfgb-~36r/" (uiop:temporary-directory)
                       (random (expt 36 8) (make-random-state t)))))
         (old (uiop:getenv "CL_REPO_CONFIG_CACHE")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") (uiop:native-namestring dir))
           (setf (fdefinition sym)
                 (lambda (requests)
                   (mapcar (lambda (r)
                             (destructuring-bind (registry method path &rest keys) r
                               (declare (ignore registry keys))
                               (push (list method path) sent)
                               (let ((answer (cdr (assoc path routes :test #'string=))))
                                 (cond ((null answer)
                                        (make-condition 'cl-oci-client/conditions:not-found-error
                                                        :status 404))
                                       ((eq method :head) (list nil 200 (third answer)))
                                       (t answer)))))
                           requests)))
           (let ((cl-repository-client/constraint-builder::*resolution-cache*
                   (cl-repository-client/constraint-builder:make-resolution-cache))
                 (cl-oci-client/pull:*pull-cache* (make-hash-table :test 'equal)))
             (let ((configs (cl-repository-client/constraint-builder::prefetch-configs
                             '(("a" . "1.0") ("b" . "2.0")) *registries*)))
               (ok (equal '("a" "b") (mapcar #'cl-oci/config:config-system-name configs)))
               (ok (equal '("alexandria") (cl-oci/config:config-depends-on (first configs))))
               (ok (= 6 (length sent)) "index, manifest and blob of each, nothing else")
               (ok (= 6 (hash-table-count cl-oci-client/pull:*pull-cache*))
                   "what was pulled is there for the install")))
           ;; next run: the stored entries, after a HEAD each
           (setf sent nil)
           (let ((cl-repository-client/constraint-builder::*resolution-cache*
                   (cl-repository-client/constraint-builder:make-resolution-cache))
                 (cl-oci-client/pull:*pull-cache* (make-hash-table :test 'equal)))
             (let ((configs (cl-repository-client/constraint-builder::prefetch-configs
                             '(("a" . "1.0") ("b" . "2.0")) *registries*)))
               (ok (every #'identity configs))
               (ok (equal '(:head :head) (mapcar #'first sent)) "one HEAD each")
               (ok (= 6 (hash-table-count cl-oci-client/pull:*pull-cache*))
                   "the install gets the stored manifests and configs")
               (ok (equalp (first (gethash (list "https://fake.test" "ns/a" "1.0")
                                           cl-oci-client/pull:*pull-cache*))
                           (%octets (scripted-package "a" "1.0")))
                   "byte for byte")))
           ;; a moved tag: the stored config is not used
           (setf sent nil)
           (setf routes (append (nth-value 1 (scripted-package "a" "1.0"))
                                (nth-value 1 (scripted-package "b" "2.0" '("babel")))))
           (let ((cl-repository-client/constraint-builder::*resolution-cache*
                   (cl-repository-client/constraint-builder:make-resolution-cache)))
             (let ((configs (cl-repository-client/constraint-builder::prefetch-configs
                             '(("a" . "1.0") ("b" . "2.0")) *registries*)))
               (ok (cl-oci/config:config-system-name (first configs)))
               (ok (equal '("babel") (cl-oci/config:config-depends-on (second configs)))
                   "b moved: its new config, not the stored one")
               (ok (member '(:get "/v2/ns/b/manifests/2.0") sent :test #'equal)))))
      (setf (fdefinition sym) orig)
      (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") (or old ""))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
