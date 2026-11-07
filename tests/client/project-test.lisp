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
