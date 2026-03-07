(defpackage :cl-repository-packager/tests/discover-systems-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/asdf-plugin #:discover-provided-systems))
(in-package :cl-repository-packager/tests/discover-systems-test)

(defun make-temp-dir ()
  (let ((dir (merge-pathnames (format nil "cl-repo-test-~a/" (get-universal-time))
                              (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    dir))

(defun write-asd (dir name &optional (extra ""))
  (let ((path (merge-pathnames (format nil "~a.asd" name) dir)))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (format s "(defsystem ~s ~a :components ((:file \"main\")))~%" name extra))
    path))

(deftest test-discover-single
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "foo")
           (let ((systems (discover-provided-systems dir)))
             (ok (= (length systems) 1))
             (ok (string= (first systems) "foo"))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest test-discover-multiple
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (progn
           (write-asd dir "main-system")
           (write-asd dir "main-system-tests")
           (write-asd dir "main-system-utils")
           (let ((systems (discover-provided-systems dir)))
             (ok (= (length systems) 3))
             (ok (member "main-system" systems :test #'string=))
             (ok (member "main-system-tests" systems :test #'string=))
             (ok (member "main-system-utils" systems :test #'string=))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest test-discover-empty-dir
  (let ((dir (make-temp-dir)))
    (unwind-protect
         (let ((systems (discover-provided-systems dir)))
           (ok (null systems)))
      (uiop:delete-directory-tree dir :validate t))))
