(defpackage :cl-repository-client/tests/project-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/project #:expand-ci-env #:discover-project-system
                #:project-registry-directories #:expand-lisp-command)
  (:import-from :cl-repository-client/dep-satisfy
                #:asdf-dep-spec #:system-satisfied-p #:quicklisp-source-p))
(in-package :cl-repository-client/tests/project-test)

(deftest lisp-command-expands-to-run
  (testing "cl-repo ros … is cl-repo run -- ros …"
    (ok (equal (expand-lisp-command '("ros" "-l" "x.lisp" "-q" "--" "2026f"))
               '("run" "--" "ros" "-l" "x.lisp" "-q" "--" "2026f"))))
  (testing "leading --system / --overlay are cl-repo's"
    (ok (equal (expand-lisp-command
                '("ros" "--system" "foo/update" "--overlay" "cuda" "-l" "x.lisp"))
               '("run" "--system" "foo/update" "--overlay" "cuda" "--" "ros" "-l" "x.lisp"))))
  (testing "after the first lisp argument everything is the lisp's"
    (ok (equal (expand-lisp-command '("sbcl" "--script" "t.lisp" "--system" "x"))
               '("run" "--" "sbcl" "--script" "t.lisp" "--system" "x")))
    (ok (equal (expand-lisp-command '("ros" "run"))
               '("run" "--" "ros" "run")))
    (ok (equal (expand-lisp-command '("ros" "--help"))
               '("run" "--" "ros" "--help"))))
  (testing "other commands are unchanged"
    (ok (equal (expand-lisp-command '("sync" "--system" "x")) '("sync" "--system" "x")))
    (ok (equal (expand-lisp-command '("run" "--" "ros")) '("run" "--" "ros")))
    (ok (null (expand-lisp-command '())))))

(deftest asdf-version-dep-keeps-minimum
  (multiple-value-bind (name minimum) (asdf-dep-spec '(:version "Foo" "1.2.3"))
    (ok (string= name "foo"))
    (ok (string= minimum "1.2.3"))))

(deftest missing-system-is-not-satisfied
  (ng (system-satisfied-p "cl-repo-no-such-system")))

(deftest quicklisp-source-matches-directory
  (let* ((sys (asdf:find-system "uiop"))
         (dir (asdf:system-source-directory sys))
         (from-dir (and dir (search "quicklisp" (namestring dir) :test #'char-equal))))
    (ok (eq (not (null from-dir))
            (not (null (quicklisp-source-p sys)))))))

(deftest ci-env-selects-the-configured-system
  (let ((previous (uiop:getenv "CL_REPO_ENV_TEST")))
    (unwind-protect
         (progn
           (setf (uiop:getenv "CL_REPO_ENV_TEST") "libev")
           (multiple-value-bind (install load)
               (expand-ci-env '(("CL_REPO_ENV_TEST"
                                 :default "libuv"
                                 :systems (("libuv" "event-backend-libuv")
                                           ("libev" "event-backend-libev"))
                                 :install t
                                 :load-before-test t)))
             (ok (equal install '("event-backend-libev")))
             (ok (equal load '("event-backend-libev")))))
      (if previous
          (setf (uiop:getenv "CL_REPO_ENV_TEST") previous)
          (uiop:run-program "unset CL_REPO_ENV_TEST" :ignore-error-status t)))))

(deftest ci-env-rejects-unknown-values
  (ok (handler-case
          (progn
            (expand-ci-env '(("CL_REPO_ENV_TEST_MISSING"
                              :systems (("only" "only-system")))))
            nil)
        (error () t))))

(deftest discover-qlfile-without-asd
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-proj-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (out (merge-pathnames "qlfile" dir) :direction :output)
             (write-line "ql alexandria" out))
           (ok (null (discover-project-system dir))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defun call-with-env (name value fn)
  (let ((previous (uiop:getenv name)))
    (unwind-protect
         (progn (setf (uiop:getenv name) value)
                (funcall fn))
      (setf (uiop:getenv name) (or previous "")))))

(deftest registry-keeps-the-client-install-tree
  ;; ci-base: CL_REPOSITORY_CLIENT_DIR is .../cl-oci-X/, its deps live in DEST.
  (let* ((dest (uiop:ensure-directory-pathname
                (uiop:merge-pathnames* "cl-repo-dest-test/" (uiop:temporary-directory))))
         (client (merge-pathnames "cl-oci-0.0.0/" dest))
         (project (uiop:getcwd)))
    (call-with-env "CL_REPOSITORY_DEST" (namestring dest)
      (lambda ()
        (call-with-env "CL_REPOSITORY_CLIENT_DIR" (namestring client)
          (lambda ()
            (let ((dirs (project-registry-directories project)))
              (ok (member dest dirs :test #'uiop:pathname-equal))
              (ok (member client dirs :test #'uiop:pathname-equal))
              (ok (uiop:pathname-equal project (first dirs))))))))))

(deftest registry-lists-each-tree-once
  (let ((dest (uiop:getcwd)))
    (call-with-env "CL_REPOSITORY_DEST" (namestring dest)
      (lambda ()
        (ok (= 1 (count dest (project-registry-directories dest)
                        :test #'uiop:pathname-equal)))))))

(defvar cl-user::*cl-repo-pretest-ran* nil)

(deftest pre-test-runs-after-registry-setup-before-load
  "CMD-TEST's PRE-TEST runs once the project is on the registry and before the
   system loads (canned CI pre-test hooks rely on both)."
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "cl-repo-pretest-~D/" (random 1000000 (make-random-state t)))
                                (uiop:temporary-directory))))
         (seen-system nil))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (o (merge-pathnames "cl-repo-pretest-demo.asd" dir) :direction :output)
             (write-string "(defsystem \"cl-repo-pretest-demo\" :components ((:file \"demo\")))" o))
           (with-open-file (o (merge-pathnames "demo.lisp" dir) :direction :output)
             (write-string "(unless cl-user::*cl-repo-pretest-ran* (error \"pre-test did not run first\"))" o))
           (setf cl-user::*cl-repo-pretest-ran* nil)
           ;; an empty install tree: no other system's init file runs here
           (let ((cl-repository-client/installer::*systems-root* (merge-pathnames "systems/" dir)))
             (ensure-directories-exist cl-repository-client/installer::*systems-root*)
           (cl-repository-client/project:cmd-test
            :directory dir :system "cl-repo-pretest-demo" :sync nil
            :pre-test (lambda ()
                        (setf seen-system (and (asdf:find-system "cl-repo-pretest-demo" nil) t)
                              cl-user::*cl-repo-pretest-ran* t))))
           (ok seen-system "the project system is findable when the hook runs")
           (ok cl-user::*cl-repo-pretest-ran*))
      (asdf:clear-system "cl-repo-pretest-demo")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

;;; A throwaway project in a temp directory whose test-op runs CHECK (a form
;;; read in the test image); cmd-test runs it in a fresh image.
(defun %fresh-image-test (name check &key pre-test)
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "~a-~D/" name (random 1000000 (make-random-state t)))
                                (uiop:temporary-directory))))
         (hook (merge-pathnames "pre-test.lisp" dir))
         (cl-repository-client/project:*test-in-subprocess* t))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (o (merge-pathnames (format nil "~a.asd" name) dir) :direction :output)
             (format o "(defsystem ~S :perform (test-op (o c) ~A))" name check))
           (when pre-test
             (with-open-file (o hook :direction :output)
               (write-string pre-test o)))
           (let ((cl-repository-client/installer::*systems-root* (merge-pathnames "systems/" dir)))
             (ensure-directories-exist cl-repository-client/installer::*systems-root*)
             (handler-case
                 (progn (cl-repository-client/project:cmd-test
                         :directory dir :system name :sync nil
                         :pre-test-file (and pre-test hook))
                        :passed)
               (cl-repository-client/project:tests-failed (e)
                 (cl-repository-client/project::tests-failed-exit-code e)))))
      (asdf:clear-system name)
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest suite-runs-in-a-fresh-image
  "cmd-test runs the suite in a new image: the client (and the cl+ssl/OpenSSL
   it loaded) is absent there, and the pre-test file ran before the load."
  #+sbcl
  (ok (eq :passed
          (%fresh-image-test
           "cl-repo-fresh-demo"
           "(progn (when (find-package \"CL-REPOSITORY-CLIENT\") (error \"client in the test image\"))
                   (unless (boundp 'cl-user::*fresh-pre-test*) (error \"pre-test did not run\")))"
           :pre-test "(defvar cl-user::*fresh-pre-test* t)")))
  #-sbcl (skip "the test image needs SBCL"))

(deftest failing-suite-signals-tests-failed
  "A test-op that errors in the test image makes cmd-test signal TESTS-FAILED
   with the image's non-zero exit code."
  #+sbcl
  (let ((result (%fresh-image-test "cl-repo-fresh-fail" "(error \"boom\")")))
    (ok (and (integerp result) (plusp result))))
  #-sbcl (skip "the test image needs SBCL"))

(deftest checkout-shadows-installed-copy
  "PREPARE-TEST finds the project's systems in the checkout, not in an
   installed copy of the same system in the store (a stale store copy ran its
   own tests/ — or failed to find them — instead of the checkout's)."
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "cl-repo-shadow-~D/" (random 1000000 (make-random-state t)))
                                (uiop:temporary-directory))))
         (project (merge-pathnames "project/" dir))
         (store (merge-pathnames "systems/" dir))
         (installed (merge-pathnames "cl-repo-shadow-demo/1.0/" store))
         (saved asdf:*source-registry-parameter*))
    (flet ((asd (where version)
             (ensure-directories-exist where)
             (with-open-file (o (merge-pathnames "cl-repo-shadow-demo.asd" where) :direction :output)
               (format o "(defsystem \"cl-repo-shadow-demo\" :version ~S)" version))))
      (unwind-protect
           (progn
             (asd project "2.0")
             (asd installed "1.0")
             (let ((cl-repository-client/installer::*systems-root* store))
               (cl-repository-client/project::prepare-test
                :directory project :system "cl-repo-shadow-demo"))
             (let ((system (asdf:find-system "cl-repo-shadow-demo")))
               (ok (equal "2.0" (asdf:component-version system)))
               ;; Truenames: ASDF reports /private/var/... for macOS's /var/... temp dir.
               (ok (uiop:subpathp (truename (asdf:system-source-file system))
                                  (truename project)))))
        (asdf:clear-system "cl-repo-shadow-demo")
        (asdf:initialize-source-registry saved)
        (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))

(deftest ql-entry-reference-ignores-qlot-dist-dates
  "A qlot qlfile.lock pins `ql yason` to the dist date ql-2025-06-22. That is not
   an OCI tag; installing it 404'd and sync tried to republish yason."
  (let ((ref (fdefinition 'cl-repository-client/project::ql-entry-reference)))
    (ok (string= "yason" (funcall ref "yason" "ql-2025-06-22")))
    (ok (string= "yason" (funcall ref "yason" nil)))
    (ok (string= "yason" (funcall ref "yason" "latest")))
    (ok (string= "yason:0.8.3" (funcall ref "yason" "0.8.3")))))

(defmacro with-stubbed-install ((calls &key fail-on fail-with) &body body)
  "Run BODY with cmd-install recording each reference in CALLS. A reference
   equal to FAIL-ON signals the condition FAIL-WITH builds."
  (let ((orig (gensym)) (sym ''cl-repository-client/commands::cmd-install))
    `(let ((,orig (fdefinition ,sym)))
       (unwind-protect
            (progn
              (setf (fdefinition ,sym)
                    (lambda (reference &rest keys)
                      (declare (ignore keys))
                      (push reference ,calls)
                      (when (equal reference ,fail-on)
                        (error (funcall ,fail-with)))
                      t))
              ,@body)
         (setf (fdefinition ,sym) ,orig)))))

(deftest install-or-publish-publishes-only-absent-packages
  (let ((iop (fdefinition 'cl-repository-client/project::install-or-publish)))
    (dolist (absent (list (lambda () (make-condition 'cl-oci-client/conditions:not-found-error
                                                     :status 404))
                          (lambda () (make-condition 'cl-oci-client/conditions:auth-error
                                                     :status 401))))
      (let ((calls '()) (published nil))
        (with-stubbed-install (calls :fail-on "foo:1.0" :fail-with absent)
          (funcall iop "foo:1.0" (lambda () (setf published t))))
        (ok published)
        (ok (equal '("foo" "foo:1.0") calls))))
    (testing "a registry outage is not a missing package"
      (let ((calls '()) (published nil))
        (ok (signals
             (with-stubbed-install (calls :fail-on "foo:1.0"
                                          :fail-with (lambda ()
                                                       (make-condition
                                                        'cl-oci-client/conditions:registry-error
                                                        :status 503)))
               (funcall iop "foo:1.0" (lambda () (setf published t))))
             'cl-oci-client/conditions:registry-error))
        (ng published)))
    (testing "an unrelated error propagates"
      (let ((calls '()) (published nil))
        (ok (signals
             (with-stubbed-install (calls :fail-on "foo"
                                          :fail-with (lambda () (make-condition 'simple-error
                                                                                :format-control "tls")))
               (funcall iop "foo" (lambda () (setf published t))))
             'simple-error))
        (ng published)))))

(deftest explicit-tag-p-reads-only-the-last-segment
  (let ((f (fdefinition 'cl-repository-client/commands::explicit-tag-p)))
    (ok (null (funcall f "yason")))
    (ok (funcall f "yason:0.8.3"))
    (ok (funcall f "ghcr.io/ns/yason@sha256:abc"))
    (ok (null (funcall f "localhost:5050/ns/yason")))))

(deftest install-or-publish-skips-oci-install-after-a-local-install
  "Without write access a publish installs the source locally; the bare-name
   OCI install after it would 404 again."
  (let ((iop (fdefinition 'cl-repository-client/project::install-or-publish))
        (calls '()))
    (with-stubbed-install (calls :fail-on "foo"
                                 :fail-with (lambda () (make-condition
                                                        'cl-oci-client/conditions:not-found-error
                                                        :status 404)))
      (let ((sym 'cl-repository-client/asdf-integration:configure-asdf-source-registry))
        (let ((orig (fdefinition sym)))
          (unwind-protect
               (progn
                 (setf (fdefinition sym) (lambda () nil))
                 (funcall iop "foo"
                          (lambda ()
                            (setf cl-repository-client/project::*installed-locally* t))))
            (setf (fdefinition sym) orig)))))
    (ok (equal '("foo") calls))))

(deftest configure-registry-keeps-the-checkout-first
  "prepare-test re-prepended the install tree after register-project, so
   cl-repo test in http-protocol compiled an installed http-protocol 0.3.0
   instead of the checkout."
  (let* ((saved asdf:*source-registry-parameter*)
         (dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-order-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (root (cl-repository-client/installer:systems-root)))
    (ensure-directories-exist dir)
    (ensure-directories-exist root)
    (unwind-protect
         (progn
           (cl-repository-client/project::register-project dir)
           (let ((before asdf:*source-registry-parameter*))
             (cl-repository-client/asdf-integration:configure-asdf-source-registry)
             (ok (equal before asdf:*source-registry-parameter*))
             (ok (uiop:pathname-equal
                  dir (uiop:ensure-directory-pathname
                       (second (find :tree (rest asdf:*source-registry-parameter*)
                                     :key (lambda (e) (and (consp e) (car e))))))))))
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest project-registry-skips-leftover-qlot-trees
  "http-protocol's leftover .qlot/ made vom, cl-ppcre, ... resolve to Quicklisp
   copies, so cl-repo test reported them missing."
  (let* ((saved asdf:*source-registry-parameter*)
         (dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-qlot-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (hidden (merge-pathnames ".qlot/dists/x/" dir)))
    (ensure-directories-exist hidden)
    (with-open-file (s (merge-pathnames "cl-repo-qlot-only.asd" hidden) :direction :output)
      (write-string "(defsystem \"cl-repo-qlot-only\")" s))
    (unwind-protect
         (progn
           (cl-repository-client/project::register-project dir)
           (ok (null (asdf:find-system "cl-repo-qlot-only" nil))))
      (asdf:clear-system "cl-repo-qlot-only")
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest configure-registry-rescans-the-install-tree
  "0.27.1: once the install tree was registered, configure-asdf-source-registry
   no longer re-initialized, so a system installed during sync (rove) stayed
   invisible: \"cl-repo: system rove is not in the registry\"."
  (let* ((saved asdf:*source-registry-parameter*)
         (dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-rescan-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (root (cl-repository-client/installer:systems-root))
         (pkg (merge-pathnames (format nil "cl-repo-rescan-demo/1.0.0-~36r/" (random (expt 36 6))) root)))
    (ensure-directories-exist dir)
    (ensure-directories-exist root)
    (unwind-protect
         (progn
           (cl-repository-client/project::register-project dir)
           ;; An install lands after the registry was scanned.
           (ensure-directories-exist pkg)
           (with-open-file (s (merge-pathnames "cl-repo-rescan-demo.asd" pkg) :direction :output)
             (write-string "(defsystem \"cl-repo-rescan-demo\")" s))
           (ng (asdf:find-system "cl-repo-rescan-demo" nil))
           (cl-repository-client/asdf-integration:configure-asdf-source-registry)
           ;; A fresh ASDF session, as the next cl-repo step has: test-op's own
           ;; session caches the NG lookup above (ASDF 3.3.7 on CI).
           (ok (let ((asdf/session:*asdf-session* nil))
                 (asdf:find-system "cl-repo-rescan-demo" nil))))
      (asdf:clear-system "cl-repo-rescan-demo")
      (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
      (uiop:delete-directory-tree (uiop:pathname-parent-directory-pathname pkg)
                                  :validate t :if-does-not-exist :ignore)
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest install-tree-prefers-the-newest-or-locked-version
  "ASDF takes the first .asd in a :tree (path order): with serdes-protocol 0.2.0
   and 0.2.2 installed, 0.2.0 won and mime-protocol 0.1.4 failed to read."
  (let* ((saved asdf:*source-registry-parameter*)
         (root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-versions-~36r/" (uiop:temporary-directory) (random (expt 36 6))))))
    (dolist (v '("0.2.0" "0.2.2" "0.10.1"))
      (let ((dir (merge-pathnames (format nil "cl-repo-multi-demo/~a/" v) root)))
        (ensure-directories-exist dir)
        (with-open-file (s (merge-pathnames "cl-repo-multi-demo.asd" dir) :direction :output)
          (format s "(defsystem \"cl-repo-multi-demo\" :version ~s)" v))))
    (flet ((resolved (locked)
             (asdf:initialize-source-registry
              `(:source-registry
                ,@(cl-repository-client/asdf-integration:preferred-install-trees root locked)
                (:tree ,(namestring root))
                :ignore-inherited-configuration))
             (asdf:clear-system "cl-repo-multi-demo")
             (let ((asdf/session:*asdf-session* nil))
               (asdf:component-version (asdf:find-system "cl-repo-multi-demo")))))
      (unwind-protect
           (progn
             (ok (equal "0.10.1" (resolved nil)) "newest, not the first in path order")
             (ok (equal "0.2.0" (resolved '(("cl-repo-multi-demo" . "0.2.0")))) "the locked version")
             (ok (equal "0.10.1" (resolved '(("cl-repo-multi-demo" . "9.9.9")))) "a lock naming no installed version"))
        (asdf:clear-system "cl-repo-multi-demo")
        (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(deftest rescan-prefers-a-version-installed-later
  "The lisp-mcp launcher registers (:tree systems) itself; after lisp-source-protocol
   0.2.1 was installed next to 0.2.0, the rescan kept resolving 0.2.0."
  (let* ((saved asdf:*source-registry-parameter*)
         (root (uiop:ensure-directory-pathname
                (format nil "~a/cl-repo-rescan-pref-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (cl-repository-client/installer::*systems-root* root)
         (cl-repository-client/asdf-integration:*locked-versions* nil))
    (flet ((install (v)
             (let ((dir (merge-pathnames (format nil "cl-repo-pref-demo/~a/" v) root)))
               (ensure-directories-exist dir)
               (with-open-file (s (merge-pathnames "cl-repo-pref-demo.asd" dir) :direction :output)
                 (format s "(defsystem \"cl-repo-pref-demo\" :version ~s)" v))))
           (resolved ()
             (asdf:clear-system "cl-repo-pref-demo")
             (let ((asdf/session:*asdf-session* nil))
               (asdf:component-version (asdf:find-system "cl-repo-pref-demo")))))
      (unwind-protect
           (progn
             (install "0.2.0")
             (asdf:initialize-source-registry
              `(:source-registry (:tree ,(namestring root)) :ignore-inherited-configuration))
             (ok (equal "0.2.0" (resolved)))
             (install "0.2.1")
             (cl-repository-client/asdf-integration:configure-asdf-source-registry)
             (ok (equal "0.2.1" (resolved)) "the newer install wins after the rescan"))
        (asdf:clear-system "cl-repo-pref-demo")
        (if saved (asdf:initialize-source-registry saved) (asdf:clear-source-registry))
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(deftest sync-roots-cover-every-system-of-the-project
  (let* ((stamp (format nil "~(~36r~)" (random (expt 36 8))))
         (main (format nil "cl-repo-roots-~a" stamp))
         (other (format nil "cl-repo-roots-tools-~a" stamp))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "~a/" main) (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (out (merge-pathnames (format nil "~a.asd" main) dir)
                                :direction :output)
             (format out "(defsystem ~s)~%(defsystem ~s :depends-on (~s))~%(defsystem ~s)~%"
                     main (format nil "~a/agent" main) main (format nil "~a/tests" main)))
           (with-open-file (out (merge-pathnames (format nil "~a.asd" other) dir)
                                :direction :output)
             (format out "(defsystem ~s)~%" other))
           (testing "every primary .asd, the directory's own first"
             (ok (equal (list main other)
                        (cl-repository-client/project::project-primary-systems dir))))
           (testing "the secondary systems that .asd defines"
             (asdf:load-asd (merge-pathnames (format nil "~a.asd" main) dir))
             (ok (equal (list (format nil "~a/agent" main) (format nil "~a/tests" main))
                        (cl-repository-client/project::project-secondary-systems main dir)))
             (ok (null (cl-repository-client/project::project-secondary-systems other dir)))))
      (dolist (name (list main (format nil "~a/agent" main) (format nil "~a/tests" main) other))
        (asdf:clear-system name))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest reload-safety-of-loaded-systems
  (ok (not (cl-repository-client/project:reload-safe-system-p "cl+ssl"))
      "cl+ssl is listed: it opens cl-stack-ssl's libcrypto")
  (ok (cl-repository-client/project:reload-safe-system-p "alexandria") "pure Lisp")
  (let ((cl-repository-client/project:*reload-unsafe-systems* '("alexandria")))
    (ok (not (cl-repository-client/project:reload-safe-system-p "alexandria"))
        "the list is consulted by primary name")))

(deftest required-minimums-walk-the-dependency-closure
  (let* ((stamp (format nil "~(~36r~)" (random (expt 36 8))))
         (main (format nil "cl-repo-mins-~a" stamp))
         (dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "~a/" main) (uiop:temporary-directory))))
         (asd (merge-pathnames (format nil "~a.asd" main) dir)))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (out asd :direction :output)
             (format out "(defsystem ~s :depends-on ((:version \"alexandria\" \"99.0\") ~s))~%(defsystem ~s :depends-on ((:version \"alexandria\" \"98.0\")))~%"
                     main (format nil "~a/part" main) (format nil "~a/part" main)))
           (asdf:load-asd asd)
           (let ((mins (cl-repository-client/project::required-minimums (list main))))
             (ok (equal "99.0" (cdr (assoc "alexandria" mins :test #'string=)))
                 "the highest minimum across the closure")))
      (asdf:clear-system main)
      (asdf:clear-system (format nil "~a/part" main))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest older-native-system-is-reported-not-reloaded
  (let ((cl-repository-client/project:*reload-unsafe-systems* '("alexandria")))
    (cl-oci-client/pin:with-loaded-systems-pinned ()
      (ok (signals (cl-repository-client/project::ensure-loaded-at-least "alexandria" "999.0")
                   'cl-repository-client/project:client-runs-older-system)
          "an unsafe system the project needs newer is an error")
      (let ((c (handler-case (cl-repository-client/project::ensure-loaded-at-least "alexandria" "999.0")
                 (cl-repository-client/project:client-runs-older-system (e) e))))
        (ok (equal "999.0" (cl-repository-client/project:older-system-required-version c)))
        (ok (search "install.sh" (princ-to-string c)) "the report says how to fix it"))
      (ok (null (handler-bind ((cl-repository-client/project:client-runs-older-system #'continue))
                  (cl-repository-client/project::ensure-loaded-at-least "alexandria" "999.0")))
          "CONTINUE keeps the loaded copy")
      (ok (asdf:component-loaded-p (asdf:registered-system "alexandria")) "still loaded"))))

(deftest explicit-source-registry-keeps-trees-drops-inheritance
  "cl-repository#99: the project registry keeps the trees CL_SOURCE_REGISTRY
   names and never inherits the user's source-registry.conf.d."
  (let ((entries (cl-repository-client/project:explicit-source-registry-entries
                  "(:source-registry (:tree \"/w/a\") (:directory \"/w/b/\") (:tree \"rel/\") (:include \"/u/x.conf\") :inherit-configuration)")))
    (ok (equal entries '((:tree "/w/a/") (:directory "/w/b/")))))
  (ok (equal (cl-repository-client/project:explicit-source-registry-entries "/w/a//:/w/b/:")
             '((:tree "/w/a/") (:directory "/w/b/"))))
  (ok (null (cl-repository-client/project:explicit-source-registry-entries "")))
  (ok (null (cl-repository-client/project:explicit-source-registry-entries nil)))
  (let* ((project (uiop:ensure-directory-pathname "/p/proj/"))
         (form (cl-repository-client/project:source-registry-form
                (list project "/p/other/")
                :extra '((:tree "/w/a/")))))
    (ok (eq :ignore-inherited-configuration (car (last form))))
    (ok (not (member :inherit-configuration form)))
    (testing "explicit trees follow the project, before the other trees"
      (let ((trees (remove-if-not (lambda (e) (and (consp e) (eq (first e) :tree))) form)))
        (ok (equal (mapcar #'second trees) '("/p/proj/" "/w/a/" "/p/other/")))))))

(deftest sync-and-test-image-share-the-explicit-trees
  "REGISTER-PROJECT (sync, test-setup) carries CL_SOURCE_REGISTRY trees; the
   test image is started with that same parameter."
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "cl-repo-99-~D/" (random 1000000 (make-random-state t)))
                                (uiop:temporary-directory))))
         (side (merge-pathnames "side/" dir))
         (project (merge-pathnames "project/" dir))
         (saved asdf:*source-registry-parameter*))
    (ensure-directories-exist side)
    (ensure-directories-exist project)
    (with-open-file (o (merge-pathnames "cl-repo-99-side.asd" side) :direction :output)
      (write-string "(defsystem \"cl-repo-99-side\" :version \"9.9.9\")" o))
    (unwind-protect
         (call-with-env "CL_SOURCE_REGISTRY"
                        (format nil "(:source-registry (:tree ~S) :inherit-configuration)"
                                (namestring side))
           (lambda ()
             (cl-repository-client/project:register-project project)
             (let ((param asdf/source-registry:*source-registry-parameter*))
               (ok (member (list :tree (namestring side)) param :test #'equal))
               (ok (not (member :inherit-configuration param))))
             (ok (system-satisfied-p "cl-repo-99-side" "9.9.9"))))
      (asdf:clear-system "cl-repo-99-side")
      (asdf:initialize-source-registry saved)
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest sbcl-startup-eval-follows-the-runtime-options
  "#130: the startup --eval goes after SBCL's runtime options; --script keeps
   its runtime implications and stays last."
  (let ((f "F"))
    (flet ((start (&rest args) (cl-repository-client/project::lisp-startup "sbcl" f args)))
      (ok (equal (start "--script" "x.lisp")
                 '("--noinform" "--disable-ldb" "--lose-on-corruption" "--end-runtime-options"
                   "--eval" "F" "--script" "x.lisp")))
      (ok (equal (start "--dynamic-space-size" "4GB" "--noinform" "--script" "x.lisp" "a")
                 '("--dynamic-space-size" "4GB" "--noinform" "--disable-ldb"
                   "--lose-on-corruption" "--end-runtime-options"
                   "--eval" "F" "--script" "x.lisp" "a")))
      (ok (equal (start "--noinform" "--non-interactive" "--eval" "(x)")
                 '("--noinform" "--eval" "F" "--non-interactive" "--eval" "(x)")))
      (ok (equal (start "--core" "c.core" "--end-runtime-options" "--load" "y")
                 '("--core" "c.core" "--end-runtime-options" "--eval" "F" "--load" "y")))
      (ok (equal (start "--non-interactive") '("--eval" "F" "--non-interactive")))
      (ok (equal (start) '("--eval" "F"))))
    (ok (equal (cl-repository-client/project::lisp-startup "/usr/local/bin/sbcl" f '("--script" "x"))
               (cl-repository-client/project::lisp-startup "sbcl" f '("--script" "x")))
        "a path to sbcl is sbcl")
    (ok (equal (cl-repository-client/project::lisp-startup "ros" f '("run"))
               '("-e" "F" "run")))))

#+sbcl
(deftest run-script-stdout-is-the-script-only
  "#130 + #121: `cl-repo run -- sbcl --script FILE` with the real startup form.
   stdout carries only the script's output (no banner), ASDF and the project
   registry are set up, and fasls go to cl-repo's own root."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "~a/cl-repo-130-~36r/" (uiop:temporary-directory) (random (expt 36 6)))))
         (script (merge-pathnames "s.lisp" dir)))
    (ensure-directories-exist dir)
    (with-open-file (o script :direction :output)
      (write-string "(format t \"out ~a~%\" (namestring (asdf:apply-output-translations \"/x/y.fasl\")))" o))
    (unwind-protect
         (let* ((form (cl-repository-client/project::run-startup-form dir))
                (args (cl-repository-client/project::lisp-startup
                       "sbcl" form
                       (list "--core" (uiop:native-namestring sb-ext:*core-pathname*)
                             "--script" (uiop:native-namestring script))))
                (out (uiop:run-program (cons (uiop:native-namestring sb-ext:*runtime-pathname*) args)
                                       :output :string :error-output nil
                                       :ignore-error-status t)))
           (ok (eql 0 (search "out " out)) "the script's line comes first")
           (ok (search "/common-lisp/cl-repo/" out) "cl-repo's fasl root")
           (ok (not (search "This is SBCL" out)) "no banner"))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest output-translations-form-reads-without-asdf
  "#121: the child form prints and reads back with standard syntax."
  (let ((form (cl-repository-client/asdf-integration:output-translations-form)))
    (ok (equal form (with-standard-io-syntax
                      (read-from-string (prin1-to-string form)))))))

(defun %race-system (dir files)
  "Write DIR/cl-repo-race-162.asd, a serial system of FILES tiny files."
  (ensure-directories-exist dir)
  (dotimes (i files)
    (with-open-file (o (merge-pathnames (format nil "f~d.lisp" i) dir)
                       :direction :output :if-exists :supersede)
      (format o "(defpackage :cl-repo-race-162-~d (:use :cl)) (in-package :cl-repo-race-162-~d) (defun f (x) (1+ x))~%"
              i i)))
  (with-open-file (o (merge-pathnames "cl-repo-race-162.asd" dir)
                     :direction :output :if-exists :supersede)
    (format o "(defsystem \"cl-repo-race-162\" :serial t :components (~{(:file \"f~d\")~^ ~}))~%"
            (loop for i below files collect i))))

#+sbcl
(deftest issue-162-parallel-images-compile-into-the-shared-cache
  "cl-repository#162: two cl-repo runs that compile the same files into the
   shared fasl root (~/.cache/common-lisp/cl-repo/<impl>/) kill each
   other's load: \"Couldn't load …fasl: file does not exist\". Here three
   images started as cl-repo test starts its fresh image (TEST-IMAGE-COMMAND,
   the TEST-IMAGE-FORMS before the project load) and three started as
   `cl-repo run -- sbcl` (RUN-STARTUP-FORM) force-load one 120-file system
   twenty times each, all at once. Every one must load it every time.
   UIOP 3.3.1 COMPILE-FILE* deletes the fasl before it renames the staging
   file over it and then takes its TRUENAME, so another image's delete
   lands in that window; seeding *RANDOM-STATE* alone does not close it.
   On 0.27.33 a run of this has a few failed loads (it is a race: a lucky
   run can pass)."
  (let ((command (cl-repository-client/project::test-image-command)))
    (if (null command)
        (skip "needs an SBCL whose core is a separate file")
        (let* ((dir (uiop:ensure-directory-pathname
                     (format nil "~a/cl-repo-162-~36r/" (uiop:temporary-directory)
                             (random (expt 36 6) (make-random-state t)))))
               (asd (uiop:native-namestring (merge-pathnames "cl-repo-race-162.asd" dir)))
               (work (with-standard-io-syntax
                         (format nil "(progn (setf *compile-verbose* nil *compile-print* nil) (asdf:load-asd ~s) (let ((fails 0)) (dotimes (i 20) (handler-case (asdf:load-system \"cl-repo-race-162\" :force t) (error (e) (incf fails) (format t \"~~&RACE-FAIL ~~a~~%\" e)))) (format t \"~~&RACE-DONE ~~d~~%\" fails)))"
                                 asd)))
               (test-image (append command
                                   (loop for form in (butlast (cl-repository-client/project::test-image-forms
                                                               "cl-repo-race-162" nil nil)
                                                              2)
                                         append (list "--eval" form))
                                   (list "--eval" work)))
               (run-image (cons (uiop:native-namestring sb-ext:*runtime-pathname*)
                                (cl-repository-client/project::lisp-startup
                                 "sbcl" (cl-repository-client/project::run-startup-form dir)
                                 (list "--core" (uiop:native-namestring sb-ext:*core-pathname*)
                                       "--noinform" "--non-interactive" "--no-sysinit" "--no-userinit"
                                       "--eval" work))))
               (images (list test-image run-image test-image run-image test-image run-image))
               (logs (loop for i below (length images)
                           collect (merge-pathnames (format nil "image-~d.log" i) dir))))
          (%race-system dir 120)
          (unwind-protect
              (let* ((processes (loop for argv in images
                                      for log in logs
                                      collect (uiop:launch-program argv :output log
                                                                        :if-output-exists :supersede
                                                                        :error-output nil)))
                     (outputs (progn (mapc #'uiop:wait-process processes)
                                (mapcar #'uiop:read-file-string logs)))
                     (failures (loop for out in outputs
                                     for start = 0
                                     append (loop for at = (search "RACE-FAIL" out :start2 start)
                                                  while at
                                                  collect (subseq out at (min (length out) (+ at 140)))
                                                  do (setf start (1+ at))))))
                (ok (every (lambda (out) (search "RACE-DONE" out)) outputs)
                    "every image ran its twenty loads")
                (ok (null failures)
                    (format nil "no load failed (~d failed: ~{~a~^ | ~})"
                            (length failures) (subseq failures 0 (min 3 (length failures))))))
            (uiop:delete-directory-tree (uiop:ensure-directory-pathname
                                         (asdf:apply-output-translations dir))
                                        :validate t :if-does-not-exist :ignore)
            (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))))

(deftest issue-166-cl-repo-ros-starts-without-quicklisp
  "cl-repository#166: `cl-repo ros -l tool.lisp -q` (README) ran Roswell's
   default init, which loads Roswell's Quicklisp, so a system the project
   registry lacks (a missing :depends-on) loaded from the Quicklisp dist
   without a word. The image cl-repo starts for `ros` must have no Quicklisp."
  (let ((probe "(format t \"~&QL=~:[NIL~;T~]~%\" (find-package \"QL\"))"))
    (flet ((quicklisp-p (args)
             (let ((out (ignore-errors
                          (uiop:run-program (cons "ros" args) :output :string
                                                              :error-output nil
                                                              :ignore-error-status t))))
               (cond ((null out) :no-ros)
                     ((search "QL=T" out) t)
                     ((search "QL=NIL" out) nil)
                     (t :no-answer)))))
      (let ((plain (quicklisp-p (list "-e" probe "-q"))))
        (cond
         ((eq plain :no-ros) (skip "needs Roswell (ros) on PATH"))
         ((not (eq plain t)) (skip "this Roswell loads no Quicklisp by default: nothing to leak"))
         (t
          (let ((dir (uiop:ensure-directory-pathname
                      (format nil "~a/cl-repo-166-~36r/" (uiop:temporary-directory)
                              (random (expt 36 6) (make-random-state t))))))
            (ensure-directories-exist dir)
            (unwind-protect
                (let ((got (quicklisp-p (cl-repository-client/project::lisp-startup
                                         "ros" (cl-repository-client/project::run-startup-form dir)
                                         (list "-e" probe "-q")))))
                  (ok (null got)
                      (format nil "no Quicklisp in the image `cl-repo ros -e … -q` starts (got ~a)"
                              got)))
              (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore)))))))))
