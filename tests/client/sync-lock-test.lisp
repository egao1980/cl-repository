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

(deftest issue-163-an-unreproducible-lock-entry-does-not-kill-a-fresh-sync
  "cl-repository#163: `cl-repo install cl-utilities` pulls its only tag, a
   commit sha, into cl-utilities/latest/, and the next sync locks it as
   (:version \"latest\" :index-digest \"\" :registry \"\"). On a machine
   without that directory the sync from the lock pulled the tag latest,
   which no registry has, and NOT-FOUND killed the job (http-protocol CI)."
  (with-fake-registry (dir)
    (sync dir)
    (let ((lock (merge-pathnames "cl-repo.lock" dir))
          (pulled '()))
      (write-lockfile (append (read-lockfile lock)
                              (list (make-instance 'lockfile-entry
                                                   :system "cl-repo-lk-u" :version "latest"
                                                   :index-digest "" :registry "")))
                      lock)
      (with-stubs ((cl-repository-client/installer:install-system
                    (lambda (url repository reference &key type)
                      (push (cons (repository-name repository) reference) pulled)
                      (if (string= reference "latest")
                          (error 'cl-oci-client/conditions:not-found-error
                                 :url (format nil "~a/v2/~a/manifests/latest" url repository))
                          (fake-install url repository reference :type type)))))
        (let ((err (handler-case (progn (sync dir) nil)
                     (cl-oci-client/conditions:not-found-error (e) e))))
          (ok (null err) (format nil "the sync does not die with ~a" err))
          (ok (not (member '("cl-repo-lk-u" . "latest") pulled :test #'equal))
              "the tag latest is not pulled"))))))

(deftest issue-165-a-missing-minimum-is-not-reported-as-a-missing-system
  "cl-repository#165: the project needs cl-repo-lk-b >= 3.0 and the registry
   has 1.0 and 2.0. The sync fails, as it should, but it said the system is
   not in the registry at all (cl-stack-code#52: agent-tools 0.4.1 required,
   0.4.0 published)."
  (with-fake-registry (dir)
    (with-open-file (o (merge-pathnames (format nil "~a.asd" *project*) dir)
                       :direction :output :if-exists :supersede)
      (format o "(defsystem ~s :depends-on ((:version \"cl-repo-lk-b\" \"3.0\")))~%" *project*))
    (let ((message (handler-case (progn (sync dir) nil)
                     (error (e) (princ-to-string e)))))
      (ok message "the sync fails")
      (ok (and message (not (search "not in the registry" message)))
          (format nil "not \"not in the registry\": ~a" message))
      (ok (and message (search "3.0" message) (search "2.0" message))
          "it names the minimum and the newest version the registry has"))))

(deftest issue-167-sync-resolves-to-the-newest-published-version
  "cl-repository#167: lk-b 1.0 is already installed (another project, a
   `cl-repo install`), the registry has 1.0 and 2.0, there is no lock. The
   sync kept 1.0, so two machines resolve one .asd differently. README:
   resolution starts from the newest acceptable version of each package."
  (with-fake-registry (dir)
    (let ((old (fake-install "https://fake.test" "ns/cl-repo-lk-b" "1.0")))
      (cl-repository-client/digest-cache:record-installed-digest
       (cl-repository-client/installer:install-result-index-digest old)
       (cl-repository-client/installer:install-result-path old)))
    (sync dir)
    (ok (equal '("cl-repo-lk-b" "2.0" "sha256:cl-repo-lk-b-2.0" "https://fake.test")
               (assoc "cl-repo-lk-b" (lock-of dir) :test #'string=))
        (format nil "the lock has the newest published lk-b: ~s"
                (assoc "cl-repo-lk-b" (lock-of dir) :test #'string=)))
    (ok (equal '(("cl-repo-lk-b" . "2.0")) (closure-packages '("cl-repo-lk-b")))
        "and a fresh image loads it")))

(deftest issue-167-a-client-tree-package-resolves-to-the-newest-published-version
  "cl-repository#167, a copy in the client's tree: the project needs lk-b,
   and lk-b 1.0 sits in CL_REPOSITORY_DEST (~/.cl-repository-client, where
   the client keeps its own alexandria, http-protocol 0.4.2,
   http-backend-async 0.2.27, ...). The registry has 1.0 and 2.0, there is
   no lock. The sync installs and locks nothing of lk-b, and the fresh image
   loads the client's 1.0. End to end with client 0.27.34 (PR 174) in a
   fresh HOME, `(defsystem \"px167\" :depends-on (\"http-protocol\"))`:
   `cl-repo sync` wrote cl-repo.lock (0 packages), and `cl-repo ros` loaded
   http-protocol 0.4.2 from ~/.cl-repository-client/http-protocol-0.4.2/
   while GHCR publishes 0.4.3."
  (with-fake-registry (dir)
    (write-asd dir '("cl-repo-lk-b"))
    (let* ((dest (merge-pathnames "client-dest/" (uiop:pathname-parent-directory-pathname dir)))
           (lk-b (merge-pathnames "cl-repo-lk-b-1.0/" dest))
           (old-dest (uiop:getenv "CL_REPOSITORY_DEST")))
      (ensure-directories-exist lk-b)
      (with-open-file (o (merge-pathnames "cl-repo-lk-b.asd" lk-b)
                         :direction :output :if-exists :supersede)
        (format o "(defsystem \"cl-repo-lk-b\" :version \"1.0\")~%"))
      (setf (uiop:getenv "CL_REPOSITORY_DEST") (namestring dest))
      (unwind-protect
          (progn
            (sync dir)
            (ok (equal '("cl-repo-lk-b" "2.0" "sha256:cl-repo-lk-b-2.0" "https://fake.test")
                       (assoc "cl-repo-lk-b" (lock-of dir) :test #'string=))
                (format nil "the lock has the newest published lk-b (lock: ~s)" (lock-of dir)))
            (ok (equal '(("cl-repo-lk-b" . "2.0")) (closure-packages '("cl-repo-lk-b")))
                (format nil "and a fresh image loads it, not ~a"
                        (asdf/source-registry:sysdef-source-registry-search "cl-repo-lk-b"))))
        (setf (uiop:getenv "CL_REPOSITORY_DEST") (or old-dest ""))))))

(deftest issue-169-a-sync-for-a-fresh-image-does-not-say-it-runs-the-client-copy
  "cl-repository#169: the client image runs lk-b 1.0, the project needs
   lk-b >= 2.0 and its lock has 2.0. `cl-repo ros`, `run` and `test` sync in
   the client image, then start a fresh image, which loads the locked 2.0
   (first check). The sync from the lock still warned
   LOADED-SYSTEM-SHADOWS-NEWER: \"this image will not load 2.0. Code that
   needs 2.0 runs against the older copy\", the opposite of what then
   happens (second check)."
  (with-fake-registry (dir)
    (with-open-file (o (merge-pathnames (format nil "~a.asd" *project*) dir)
                       :direction :output :if-exists :supersede)
      (format o "(defsystem ~s :depends-on (\"cl-repo-lk-a\" (:version \"cl-repo-lk-b\" \"2.0\")))~%"
              *project*))
    (sync dir)
    (let* ((client (merge-pathnames "client/" (uiop:pathname-parent-directory-pathname dir)))
           (project-registry asdf:*source-registry-parameter*)
           (warnings '())
           (asdf/session:*asdf-session* nil))
      ;; the client's own copy of lk-b, 1.0, loaded in this image from its tree
      (ensure-directories-exist client)
      (with-open-file (o (merge-pathnames "cl-repo-lk-b.asd" client)
                         :direction :output :if-exists :supersede)
        (format o "(defsystem \"cl-repo-lk-b\" :version \"1.0\")~%"))
      (asdf:clear-system "cl-repo-lk-b")
      (asdf:initialize-source-registry
       `(:source-registry (:directory ,(namestring client)) :ignore-inherited-configuration))
      (asdf:load-system "cl-repo-lk-b")
      (asdf:initialize-source-registry project-registry)
      (ok (equal "1.0" (asdf:component-version (asdf:registered-system "cl-repo-lk-b")))
          "this image runs the client's lk-b 1.0")
      (let ((cl-oci-client/pin::*pinned* nil)
            (cl-oci-client/pin::*checked* nil))
        (handler-bind ((cl-oci-client/pin:loaded-system-shadows-newer
                        (lambda (w) (push w warnings) (muffle-warning w))))
          (asdf:clear-system *project*)
          (asdf:clear-system "cl-repo-lk-a")
          (cmd-sync :directory dir)))
      (ok (equal '(("cl-repo-lk-b" . "2.0")) (closure-packages '("cl-repo-lk-b")))
          "the image cl-repo ros / run / test starts loads the locked 2.0")
      (ok (null warnings)
          (format nil "the sync does not warn that the project runs the client's 1.0: ~{~a~^; ~}"
                  warnings)))))

(deftest issue-170-a-qlfile-only-project-gets-the-closure-of-its-entries
  "cl-repository#170: a directory with only a qlfile (`ql cl-repo-lk-a`) is a
   project. The sync installed and locked lk-a alone, not lk-b it depends
   on, and `cl-repo run` then failed with Component not found
   (python-to-cl CI, `ql cl-blog`). A qlfile entry is installed by
   CMD-INSTALL, which records no digest, so the lock asks the registry for
   it with a HEAD: the fake registry answers that one."
  (with-fake-registry (dir)
    (delete-file (merge-pathnames (format nil "~a.asd" *project*) dir))
    (with-open-file (o (merge-pathnames "qlfile" dir) :direction :output :if-exists :supersede)
      (write-line "ql cl-repo-lk-a" o))
    (with-stubs ((cl-oci-client/pull:head-manifest
                  (lambda (registry repository reference)
                    (declare (ignore registry))
                    (let ((headers (make-hash-table :test 'equal)))
                      (setf (gethash "docker-content-digest" headers)
                            (fake-digest (repository-name repository) reference))
                      (values 200 headers)))))
      (let ((calls (sync dir)))
        (ok (assoc "cl-repo-lk-b" (calls-installs calls) :test #'string=)
            (format nil "lk-b is installed (installs: ~s)" (calls-installs calls)))
        (ok (equal '("cl-repo-lk-a" "cl-repo-lk-b") (mapcar #'first (lock-of dir)))
            (format nil "and locked beside lk-a (lock: ~s)" (lock-of dir)))))))

;;; Edge cases of the fixes for #163, #165, #167 and #170

(defun lock-entry-for (system version digest registry)
  (make-instance 'lockfile-entry :system system :version version
                                 :index-digest digest :registry registry))

(defun add-lock-entry (dir entry)
  (let ((lock (merge-pathnames "cl-repo.lock" dir)))
    (write-lockfile (append (read-lockfile lock) (list entry)) lock)))

(defun write-asd (dir depends-on)
  (with-open-file (o (merge-pathnames (format nil "~a.asd" *project*) dir)
                     :direction :output :if-exists :supersede)
    (format o "(defsystem ~s :depends-on ~s)~%" *project* depends-on)))

(defun preinstall (name version)
  "Install NAME VERSION as an earlier sync or `cl-repo install` would have,
   its digest recorded."
  (let ((result (fake-install "https://fake.test" (format nil "ns/~a" name) version)))
    (cl-repository-client/digest-cache:record-installed-digest
     (cl-repository-client/installer:install-result-index-digest result)
     (cl-repository-client/installer:install-result-path result))))

(defun not-found-for-latest (registry repository reference)
  "PULL-MANIFEST-RAW of a registry that has no tag latest."
  (if (string= reference "latest")
      (error 'cl-oci-client/conditions:not-found-error
             :url (format nil "https://fake.test/v2/~a/manifests/latest" repository))
      (fake-manifest registry repository reference)))

(deftest a-locked-latest-with-a-digest-is-pulled-by-its-digest
  "cl-repository#163: a package with no :version installs as \"latest\" from
   another tag (cl-utilities: its one tag is a commit). Once the install
   recorded its digest the lock entry has one, and a fresh machine, which has
   no tag latest to pull, pulls the digest. Nothing is resolved."
  (with-fake-registry (dir)
    (sync dir)
    (add-lock-entry dir (lock-entry-for "cl-repo-lk-u" "latest"
                                        (fake-digest "cl-repo-lk-u" "latest") "https://fake.test"))
    (let ((pulled '()))
      (with-stubs ((cl-oci-client/pull:pull-manifest-raw #'not-found-for-latest)
                   (cl-repository-client/installer:install-system
                    (lambda (url repository reference &key type)
                      (push reference pulled)
                      ;; installed under the config's version, as the installer does
                      (fake-install url repository
                                    (if (search "sha256:" reference) "latest" reference)
                                    :type type))))
        (let ((calls (sync dir)))
          (ok (quiet-p calls) "the lock is current: nothing resolved")
          (ok (equal (list (fake-digest "cl-repo-lk-u" "latest")) pulled)
              (format nil "pulled by its digest: ~s" pulled))
          (ok (uiop:directory-exists-p (system-install-path "cl-repo-lk-u" "latest"))))))))

(deftest an-installed-entry-without-a-source-keeps-the-lock-current
  "cl-repository#163: the machine that has cl-utilities/latest/ installed
   needs nothing from a registry, so the entry without registry or digest is
   no reason to resolve there."
  (with-fake-registry (dir)
    (sync dir)
    (fake-install "https://fake.test" "ns/cl-repo-lk-u" "latest")
    (add-lock-entry dir (lock-entry-for "cl-repo-lk-u" "latest" "" ""))
    (let ((calls (sync dir)))
      (ok (quiet-p calls) "nothing resolved, listed or requested")
      (ok (null (calls-installs calls)) "nothing installed"))))

(deftest locked-fails-on-an-entry-it-cannot-install
  "cl-repository#163: under --locked an entry with no registry or digest that
   is not installed makes the lock not current, and says which; it is not
   pulled as a tag."
  (with-fake-registry (dir)
    (sync dir)
    (add-lock-entry dir (lock-entry-for "cl-repo-lk-u" "latest" "" ""))
    (let ((e (handler-case (progn (sync dir :locked t) nil)
               (lockfile-not-current (e) e))))
      (ok e "LOCKFILE-NOT-CURRENT")
      (ok (and e (search "no registry or digest for cl-repo-lk-u latest" (princ-to-string e)))
          (format nil "says why: ~a" e))
      (ok (quiet-p *calls*) "nothing resolved or pulled"))))

(deftest cl-repo-install-records-the-digest-it-installed
  "cl-repository#163: CMD-INSTALL (`cl-repo install`, qlfile entries)
   recorded no digest, so a lock written later had none for its packages and
   asked the registry by tag, which for a \"latest\" install has no answer."
  (with-fake-registry (dir)
    (declare (ignore dir))
    (cl-repository-client/commands:cmd-install "cl-repo-lk-c")
    (ok (equal (namestring (system-install-path "cl-repo-lk-c" "1.0"))
               (gethash (fake-digest "cl-repo-lk-c" "1.0")
                        cl-repository-client/digest-cache:*installed-digests*)))))

(deftest a-missing-minimum-installs-nothing-of-an-older-version
  "cl-repository#165: the project needs lk-a >= 2.0 and only lk-a 1.0, which
   needs lk-b, is published. The sync installed lk-b, a dependency of the
   version it then rejected, before it failed. It signals
   UNSATISFIED-DEPENDENCIES and installs nothing."
  (with-fake-registry (dir)
    (write-asd dir '((:version "cl-repo-lk-a" "2.0")))
    (let ((e (handler-case (progn (sync dir) nil)
               (cl-repository-client/quickload:unsatisfied-dependencies (e) e))))
      (ok e "UNSATISFIED-DEPENDENCIES")
      (ok (and e (equal '(("cl-repo-lk-a" . "2.0"))
                        (cl-repository-client/quickload:unsatisfied-dependencies-systems e)))
          "names the system and its minimum")
      (ok (and e (search "cl-repo-lk-a 2.0 or later is required; the registry has 1.0"
                         (princ-to-string e)))
          (format nil "~a" e))
      (ok (null (calls-installs *calls*))
          (format nil "nothing installed: ~s" (calls-installs *calls*)))))
  (testing "a system with no published version at all is not in the registry"
    (with-fake-registry (dir)
      (write-asd dir '((:version "cl-repo-lk-zz" "1.0")))
      (let ((message (handler-case (progn (sync dir) nil)
                       (error (e) (princ-to-string e)))))
        (ok (and message (search "system cl-repo-lk-zz is not in the registry" message))
            (format nil "~a" message))))))

(deftest a-locked-older-version-stays-when-the-lock-is-stale
  "cl-repository#167: the newest published version is for packages the lock
   does not hold. A lock that holds lk-b 1.0 and goes stale (the .asd
   changed) resolves again, and lk-b stays at 1.0."
  (with-fake-registry (dir)
    (sync dir)
    (write-lockfile (mapcar (lambda (e)
                              (if (string= (lockfile-entry-system e) "cl-repo-lk-b")
                                  (lock-entry-for "cl-repo-lk-b" "1.0"
                                                  (fake-digest "cl-repo-lk-b" "1.0")
                                                  "https://fake.test")
                                  e))
                            (read-lockfile (merge-pathnames "cl-repo.lock" dir)))
                    (merge-pathnames "cl-repo.lock" dir))
    (sync dir)
    (touch-project dir)
    (let ((calls (sync dir)))
      (ok (resolved-p calls) "resolved")
      (ok (equal '("cl-repo-lk-b" "1.0" "sha256:cl-repo-lk-b-1.0" "https://fake.test")
                 (assoc "cl-repo-lk-b" (lock-of dir) :test #'string=))
          (format nil "lk-b stays locked at 1.0: ~s" (assoc "cl-repo-lk-b" (lock-of dir)
                                                           :test #'string=))))))

(deftest an-unreachable-registry-keeps-the-installed-version
  "cl-repository#167: when no registry can be asked for lk-b's versions, the
   installed 1.0 stays, as before, and the sync succeeds."
  (with-fake-registry (dir)
    (dolist (name *fake-systems*)
      (preinstall name "1.0"))
    (let ((cl-repository-client/constraint-builder::*version-lister*
            (lambda (name registries)
              (declare (ignore registries))
              (error 'cl-repository-client/constraint-builder:system-lookup-error
                     :name name :failures nil))))
      (sync dir))
    (ok (equal "1.0" (second (assoc "cl-repo-lk-b" (lock-of dir) :test #'string=)))
        (format nil "lk-b 1.0 kept: ~s" (lock-of dir)))))

(deftest a-qlfile-entry-beside-an-asd-gets-its-closure
  "cl-repository#170: the project's .asd needs lk-c, and its qlfile adds lk-a,
   which needs lk-b. lk-b is installed and locked too, and the next sync
   installs from that lock."
  (with-fake-registry (dir)
    (write-asd dir '("cl-repo-lk-c"))
    (with-open-file (o (merge-pathnames "qlfile" dir) :direction :output :if-exists :supersede)
      (write-line "ql cl-repo-lk-a" o))
    (let ((calls (sync dir)))
      (ok (assoc "cl-repo-lk-b" (calls-installs calls) :test #'string=)
          (format nil "lk-b is installed (installs: ~s)" (calls-installs calls)))
      (ok (equal '("cl-repo-lk-a" "cl-repo-lk-b" "cl-repo-lk-c") (mapcar #'first (lock-of dir)))
          (format nil "and locked (lock: ~s)" (lock-of dir))))
    (ok (quiet-p (sync dir)) "the next sync installs from the lock")))
