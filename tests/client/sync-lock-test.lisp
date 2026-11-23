(defpackage :cl-repository-client/tests/sync-lock-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/project #:cmd-sync #:cmd-test)
  (:import-from :cl-repository-client/sync-lock
                #:lockfile-not-current #:lockfile-stale-reason #:closure-packages)
  (:import-from :cl-repository-client/commands #:lockfile-digest-mismatch)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-entry #:read-lockfile #:write-lockfile
                #:lockfile-entry-system #:lockfile-entry-version
                #:lockfile-entry-index-digest #:lockfile-entry-registry)
  (:import-from :cl-repository-client/installer #:make-install-result #:system-install-path)
  (:import-from :cl-oci/config #:cl-system-config))
(in-package :cl-repository-client/tests/sync-lock-test)

;;; A project synced against a fake registry (cl-repository#155). The
;;; project depends on lk-a, which needs lk-b (1.0 and 2.0 published), and
;;; its :ci :with installs lk-c. A sync that resolves asks the version
;;; lister and the config fetcher, and reinstalls the :with extra (always
;;; forced); a sync from a current cl-repo.lock asks neither. Installs are
;;; fake: an .asd in the install tree. A request that reaches the network
;;; is an error.

(defparameter *spec*
  '(("cl-repo-lk-a" ("1.0" "cl-repo-lk-b"))
    ("cl-repo-lk-b" ("1.0") ("2.0"))
    ("cl-repo-lk-c" ("1.0"))))

(defparameter *fake-systems* '("cl-repo-lk-a" "cl-repo-lk-b" "cl-repo-lk-c"))

(defparameter *project* "cl-repo-lk-proj")

(defstruct calls (listings 0) (fetches 0) (tag-lists 0) (installs '()) (network 0))

(defvar *calls*)

(defun spec-versions (name)
  (cdr (assoc name *spec* :test #'string=)))

(defun spec-deps (name version)
  (cdr (assoc version (spec-versions name) :test #'string=)))

(defun fake-digest (name version)
  (format nil "sha256:~a-~a" name version))

(defun repository-name (repository)
  (subseq repository (1+ (position #\/ repository :from-end t))))

(defun fake-install (url repository reference &key type)
  (declare (ignore type))
  (let* ((name (repository-name repository))
         (dir (system-install-path name reference)))
    (push (cons name reference) (calls-installs *calls*))
    (ensure-directories-exist dir)
    (with-open-file (o (merge-pathnames (format nil "~a.asd" name) dir)
                       :direction :output :if-exists :supersede)
      (format o "(defsystem ~s :version ~s :depends-on ~s)~%"
              name reference (spec-deps name reference)))
    (make-install-result :path dir :name name :version reference
                         :index-digest (fake-digest name reference) :registry-url url)))

(defun fake-manifest (registry repository reference)
  (declare (ignore registry))
  (let ((headers (make-hash-table :test 'equal)))
    (setf (gethash "docker-content-digest" headers)
          (fake-digest (repository-name repository) reference))
    (values (babel:string-to-octets "{}") 200 headers)))

(defmacro with-stubs ((&rest pairs) &body body)
  "Run BODY with each (SYMBOL FUNCTION) of PAIRS as SYMBOL's definition."
  (let ((saved (gensym)))
    `(let ((,saved (list ,@(loop for pair in pairs collect `(fdefinition ',(first pair))))))
       (unwind-protect
           (progn ,@(loop for pair in pairs
                          collect `(setf (fdefinition ',(first pair)) ,(second pair)))
             ,@body)
         ,@(loop for pair in pairs
                 for i from 0
                 collect `(setf (fdefinition ',(first pair)) (nth ,i ,saved)))))))

(defun write-project (dir)
  (with-open-file (o (merge-pathnames (format nil "~a.asd" *project*) dir)
                     :direction :output :if-exists :supersede)
    (format o "(defsystem ~s :depends-on (\"cl-repo-lk-a\") ~
               :properties (:cl-repo (:ci (:with (\"cl-repo-lk-c\")))))~%"
            *project*)))

(defun touch-project (dir)
  "Rewrite the project's .asd a second after the lock: file write dates
   count whole seconds."
  (sleep 1.1)
  (write-project dir))

(defun forget-systems ()
  (dolist (name (cons *project* *fake-systems*))
    (asdf:clear-system name)))

(defun call-with-fake-registry (thunk)
  (let* ((root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-lk-~36r/" (uiop:temporary-directory)
                        (random (expt 36 8) (make-random-state t)))))
         (dir (merge-pathnames "proj/" root))
         (saved asdf:*source-registry-parameter*)
         (old-store (uiop:getenv "CL_REPO_CONFIG_CACHE"))
         (*calls* (make-calls)))
    (ensure-directories-exist dir)
    (ensure-directories-exist (merge-pathnames "systems/" root))
    (write-project dir)
    (unwind-protect
         (let ((cl-repository-client/installer::*systems-root* (merge-pathnames "systems/" root))
               (cl-repository-client/quickload:*registries* '(("https://fake.test" :namespace "ns")))
               (cl-repository-client/commands:*default-registry* "https://fake.test")
               (cl-repository-client/commands:*default-namespace* "ns")
               (cl-repository-client/protected-systems::*loaded-systems-snapshot*
                (make-hash-table :test 'equal))
               (cl-repository-client/quickload::*config-loaded* t)
               (cl-repository-client/project:*sync-with* nil)
               (cl-repository-client/project:*use-lockfile* t)
               (cl-repository-client/asdf-integration:*locked-versions* nil)
               (cl-repository-client/digest-cache:*installed-digests* (make-hash-table :test 'equal))
               (cl-repository-client/constraint-builder:*resolution-cache* nil)
               (cl-oci-client/pull:*pull-cache* nil)
               (cl-repository-client/constraint-builder::*version-lister*
                 (lambda (name registries)
                   (declare (ignore registries))
                   (incf (calls-listings *calls*))
                   (mapcar #'car (spec-versions name))))
               (cl-repository-client/constraint-builder::*config-fetcher*
                 (lambda (name version registries)
                   (declare (ignore registries))
                   (incf (calls-fetches *calls*))
                   (and (assoc version (spec-versions name) :test #'string=)
                        (make-instance 'cl-system-config :system-name name :version version
                                                         :depends-on (spec-deps name version)))))
               (cl-oci/runtime:*quiet* t))
           (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") "off")
           (with-stubs ((cl-repository-client/installer:install-system #'fake-install)
                        (cl-oci-client/pull:pull-manifest-raw #'fake-manifest)
                        (cl-oci-client/content-discovery:list-tags
                         (lambda (registry repository &rest keys)
                           (declare (ignore registry keys))
                           (incf (calls-tag-lists *calls*))
                           (mapcar #'car (spec-versions (repository-name repository)))))
                        (cl-oci-client/registry:registry-request
                         (lambda (&rest args)
                           (incf (calls-network *calls*))
                           (error "network request in a test: ~s" args)))
                        (cl-oci-client/registry:registry-request-batch
                         (lambda (&rest args)
                           (incf (calls-network *calls*))
                           (error "network request in a test: ~s" args))))
             (funcall thunk dir)))
      (forget-systems)
      (setf (uiop:getenv "CL_REPO_CONFIG_CACHE") (or old-store ""))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))

(defmacro with-fake-registry ((dir) &body body)
  `(call-with-fake-registry (lambda (,dir) ,@body)))

(defun sync (dir &rest keys)
  "CMD-SYNC of DIR, as a fresh `cl-repo sync` (nothing registered from an
   earlier one). → what it asked of the fake registry."
  (setf *calls* (make-calls))
  (forget-systems)
  (apply #'cmd-sync :directory dir keys)
  *calls*)

(defun lock-of (dir)
  (mapcar (lambda (e)
            (list (lockfile-entry-system e) (lockfile-entry-version e)
                  (lockfile-entry-index-digest e) (lockfile-entry-registry e)))
          (read-lockfile (merge-pathnames "cl-repo.lock" dir))))

(defun lock-date (dir)
  (file-write-date (merge-pathnames "cl-repo.lock" dir)))

(defparameter *closure-lock*
  '(("cl-repo-lk-a" "1.0" "sha256:cl-repo-lk-a-1.0" "https://fake.test")
    ("cl-repo-lk-b" "2.0" "sha256:cl-repo-lk-b-2.0" "https://fake.test")
    ("cl-repo-lk-c" "1.0" "sha256:cl-repo-lk-c-1.0" "https://fake.test")))

(defun resolved-p (calls)
  "Something was looked up: a version listing (resolution) or a tag listing
   (an install that picks the newest tag)."
  (plusp (+ (calls-listings calls) (calls-tag-lists calls))))

(defun quiet-p (calls)
  "Nothing was resolved, listed or requested."
  (and (zerop (calls-listings calls)) (zerop (calls-fetches calls))
       (zerop (calls-tag-lists calls)) (zerop (calls-network calls))))

(deftest sync-writes-the-closure-to-the-lock
  (with-fake-registry (dir)
    (let ((calls (sync dir)))
      (ok (resolved-p calls) "no lock: resolved")
      (ok (equal *closure-lock* (lock-of dir))
          "every package of the closure, the :with extra and the transitive lk-b included,
           with the digests of its install")
      (ok (null (lockfile-stale-reason dir)) "the lock is current"))))

(deftest a-current-lock-is-installed-without-resolving
  (with-fake-registry (dir)
    (sync dir)
    (let ((date (lock-date dir))
          (calls (sync dir)))
      (ok (quiet-p calls) "no version listing, config or tag listing")
      (ok (null (calls-installs calls)) "the forced :with extra is not reinstalled")
      (ok (= date (lock-date dir)) "the lock is left as it is"))
    (testing "cl-repo test"
      (setf *calls* (make-calls))
      (forget-systems)
      (cmd-test :directory dir :pre-test (lambda () nil))
      (ok (quiet-p *calls*)))
    (testing "an empty install tree is installed at the locked versions, by tag"
      (dolist (name *fake-systems*)
        (uiop:delete-directory-tree
         (merge-pathnames (format nil "~a/" name) (cl-repository-client/installer:systems-root))
         :validate t))
      (let ((calls (sync dir)))
        (ok (quiet-p calls))
        (ok (equal '(("cl-repo-lk-a" . "1.0") ("cl-repo-lk-b" . "2.0") ("cl-repo-lk-c" . "1.0"))
                   (sort (copy-list (calls-installs calls)) #'string< :key #'car)))
        (ok (equal *closure-lock* (lock-of dir)))))))

(deftest the-registry-loads-the-locked-version
  "lk-b 1.0 locked while 2.0 is newer: a sync installs 1.0 next to 2.0 and
   the registry resolves to it, so the lock stays current."
  (with-fake-registry (dir)
    (sync dir)
    (write-lockfile (mapcar (lambda (e)
                              (if (string= (lockfile-entry-system e) "cl-repo-lk-b")
                                  (make-instance 'lockfile-entry
                                                 :system "cl-repo-lk-b" :version "1.0"
                                                 :index-digest "sha256:cl-repo-lk-b-1.0"
                                                 :registry "https://fake.test")
                                  e))
                            (read-lockfile (merge-pathnames "cl-repo.lock" dir)))
                    (merge-pathnames "cl-repo.lock" dir))
    (let ((calls (sync dir)))
      (ok (quiet-p calls))
      (ok (equal '(("cl-repo-lk-b" . "1.0")) (calls-installs calls)))
      (ok (equal '(("cl-repo-lk-b" . "1.0")) (closure-packages '("cl-repo-lk-b")))
          "what a fresh image under this registry loads"))))

(deftest a-newer-asd-makes-the-lock-stale
  (with-fake-registry (dir)
    (sync dir)
    (touch-project dir)
    (ok (search ".asd is newer" (lockfile-stale-reason dir)))
    (let ((date (lock-date dir))
          (calls (sync dir)))
      (ok (resolved-p calls) "resolved again")
      (ok (> (lock-date dir) date) "and the lock rewritten")
      (ok (equal *closure-lock* (lock-of dir)))
      (ok (null (lockfile-stale-reason dir))))))

(deftest a-lock-that-misses-a-package-is-not-current
  (with-fake-registry (dir)
    (sync dir)
    (write-lockfile (remove "cl-repo-lk-b" (read-lockfile (merge-pathnames "cl-repo.lock" dir))
                            :key #'lockfile-entry-system :test #'string=)
                    (merge-pathnames "cl-repo.lock" dir))
    (ok (resolved-p (sync dir)) "resolved")
    (ok (equal *closure-lock* (lock-of dir)) "and the missing package locked")))

(deftest locked-fails-instead-of-resolving
  (with-fake-registry (dir)
    (ok (signals (sync dir :locked t) 'lockfile-not-current) "no lock")
    (ok (quiet-p *calls*))
    (sync dir)
    (ok (quiet-p (sync dir :locked t)) "a current lock is installed")
    (touch-project dir)
    (let ((e (handler-case (progn (sync dir :locked t) nil)
               (lockfile-not-current (e) e))))
      (ok e "a stale lock")
      (ok (and e (search ".asd is newer" (princ-to-string e))) "says why"))
    (ok (quiet-p *calls*) "nothing resolved")
    (ok (signals (sync dir :locked t :lock nil) 'error) "--locked with --no-lock")))

(deftest no-lock-resolves-and-leaves-the-lock-alone
  (with-fake-registry (dir)
    (sync dir)
    (touch-project dir)
    (let* ((leaked '())
           (date (lock-date dir))
           (before (lock-of dir))
           (calls (let ((cl-repository-client/quickload:*install-recorder*
                         (lambda (result) (push result leaked))))
                    (sync dir :lock nil))))
      (ok (resolved-p calls))
      (ok (= date (lock-date dir)) "not rewritten")
      (ok (equal before (lock-of dir)))
      (ok (calls-installs calls) "the :with extra was installed")
      (ok (null leaked) "and not added to a lock (the current directory's) either"))))

(deftest a-moved-tag-is-not-installed
  (with-fake-registry (dir)
    (sync dir)
    (uiop:delete-directory-tree
     (merge-pathnames "cl-repo-lk-c/" (cl-repository-client/installer:systems-root)) :validate t)
    (write-lockfile (mapcar (lambda (e)
                              (if (string= (lockfile-entry-system e) "cl-repo-lk-c")
                                  (make-instance 'lockfile-entry
                                                 :system "cl-repo-lk-c" :version "1.0"
                                                 :index-digest "sha256:published-again"
                                                 :registry "https://fake.test")
                                  e))
                            (read-lockfile (merge-pathnames "cl-repo.lock" dir)))
                    (merge-pathnames "cl-repo.lock" dir))
    (ok (signals (sync dir) 'lockfile-digest-mismatch))
    (ok (null (calls-installs *calls*)))))

(deftest a-package-no-registry-answers-for-gets-an-empty-digest
  ;; REMOTE-DIGEST returns a single NIL when no registry has the tag (a
  ;; quicklisp "latest" package): the entry still comes out, digest "".
  ;; 0.27.32 failed every sync with "invalid number of arguments: 1" here.
  (with-stubs ((cl-repository-client/sync-lock::local-digest
                (lambda (package version) (declare (ignore package version)) nil))
               (cl-repository-client/sync-lock::remote-digest
                (lambda (package version) (declare (ignore package version)) nil)))
    (let ((e (cl-repository-client/sync-lock::lock-entry "cl-utilities" "latest")))
      (ok (equal "cl-utilities" (lockfile-entry-system e)))
      (ok (equal "latest" (lockfile-entry-version e)))
      (ok (equal "" (lockfile-entry-index-digest e)))
      (ok (equal "" (lockfile-entry-registry e))))))
