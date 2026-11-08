(defpackage :cl-repository-client/tests/project-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/project #:expand-ci-env #:discover-project-system
                #:project-registry-directories)
  (:import-from :cl-repository-client/dep-satisfy
                #:asdf-dep-spec #:system-satisfied-p #:quicklisp-source-p))
(in-package :cl-repository-client/tests/project-test)

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
               (ok (uiop:subpathp (asdf:system-source-file system) project))))
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
