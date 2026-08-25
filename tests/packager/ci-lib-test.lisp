(defpackage :cl-repository-packager/tests/ci-lib-test
  (:use :cl :rove))
(in-package :cl-repository-packager/tests/ci-lib-test)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (load (merge-pathnames ".github/actions/ci/ci-lib.lisp"
                         (uiop:pathname-directory-pathname
                          (asdf:system-source-file "cl-repository-packager")))))

(defun make-temp-dir ()
  (let ((dir (uiop:ensure-directory-pathname
              (merge-pathnames (format nil "cl-repo-ci-lib-~a/" (get-universal-time))
                               (uiop:temporary-directory)))))
    (ensure-directories-exist dir)
    dir))

(defun write-asd (dir filename &key systems (extra ""))
  (let ((path (merge-pathnames filename dir)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (dolist (name systems)
        (format s "(defsystem ~s ~a :components ((:file \"m\")))~%" name extra)))
    path))

(deftest discover-skips-tests-and-slash-names
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "http-protocol.asd"
                      :systems '("http-protocol" "http-protocol/tests" "http-protocol/conformance"))
           (let ((names (cl-repository-ci-lib:discover-primary-systems dir)))
             (ok (equal names '("http-protocol")))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest discover-prefers-directory-name
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "foo.asd" :systems '("foo"))
           (write-asd dir "bar.asd" :systems '("bar"))
           (let* ((subdir (merge-pathnames "foo/" dir)))
             (ensure-directories-exist subdir)
             (write-asd subdir "foo.asd" :systems '("foo"))
             (write-asd subdir "bar.asd" :systems '("bar"))
             (ok (string= (cl-repository-ci-lib:discover-primary-system subdir) "foo"))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest discover-errors-when-empty
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (ok (signals (cl-repository-ci-lib:discover-primary-system dir)))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest ci-plist-from-asd
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "ci-demo.asd"
                      :systems '("ci-demo")
                      :extra ":properties (:cl-repo (:ci (:with (\"dissect\") :sources ((\"rove\" :ql)) :also-tests t)))")
           (with-open-file (s (merge-pathnames "m.lisp" dir) :direction :output :if-exists :supersede)
             (format s "(defpackage :ci-demo (:use :cl))~%"))
           (asdf:initialize-source-registry
            `(:source-registry (:directory ,(namestring dir)) :inherit-configuration))
           (asdf:clear-system "ci-demo")
           (let* ((ci (cl-repository-ci-lib:system-ci-plist "ci-demo"))
                  (with (cl-repository-ci-lib:ci-with ci '("extra")))
                  (sources (cl-repository-ci-lib:ci-sources ci)))
             (ok (cl-repository-ci-lib:ci-also-tests ci))
             (ok (member "dissect" with :test #'string=))
             (ok (member "extra" with :test #'string=))
             (ok (equal (first sources) '("rove" :ql)))))
      (asdf:clear-system "ci-demo")
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(deftest ci-defaults-when-absent
  (ok (eq (cl-repository-ci-lib:ci-also-tests nil) t))
  (ok (null (cl-repository-ci-lib:ci-with nil)))
  (ok (null (cl-repository-ci-lib:ci-sources nil)))
  (ok (null (cl-repository-ci-lib:ci-load-before-test nil)))
  (ok (null (cl-repository-ci-lib:ci-record-versions nil))))

(deftest split-ws-and-hooks
  (ok (equal (cl-repository-ci-lib:split-ws "dissect cl-stack-ssl")
             '("dissect" "cl-stack-ssl")))
  (ok (equal (cl-repository-ci-lib:split-ws "a, b") '("a" "b")))
  (let ((cl-repository-ci-lib::*extra-with* '("hooked")))
    (ok (member "hooked" (cl-repository-ci-lib:ci-with nil) :test #'string=))))

(deftest run.lisp-readable-before-packager
  "ros -l run.lisp reads the whole file before %ensure-packager. Package-qualified
   packager/oci-client symbols blow up install+test (schema-protocol canary)."
  (let* ((root (uiop:pathname-directory-pathname
                (asdf:system-source-file "cl-repository-packager")))
         (text (uiop:read-file-string (merge-pathnames ".github/actions/ci/run.lisp" root))))
    (dolist (pkg '("cl-repository-packager/asdf-plugin:"
                   "cl-repository-packager/build-matrix:"
                   "cl-repository-packager/publisher:"
                   "cl-oci-client/auth:"
                   "cl-oci-client/registry:"))
      (ok (not (search pkg text)) pkg))))
