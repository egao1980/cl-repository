(defpackage :cl-repository-client/tests/project-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/project #:expand-ci-env #:discover-project-system)
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
