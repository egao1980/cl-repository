(defpackage :cl-repository-client/tests/qlot-integration-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/qlot-integration
                #:parse-qlot-line #:read-qlfile #:read-qlfile-lock #:build-qlot-sync-plan
                #:qlot-entry-kind #:qlot-entry-name #:qlot-entry-ref
                #:read-qlfile-with-path #:read-qlfile-lock-with-path)
  (:import-from :cl-repository-client/commands #:cmd-sync-qlot)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version))
(in-package :cl-repository-client/tests/qlot-integration-test)

(deftest parse-qlot-line-basic-cases
  (let ((ql (parse-qlot-line "ql alexandria")))
    (ok (eq (qlot-entry-kind ql) :ql))
    (ok (string= (qlot-entry-name ql) "alexandria"))
    (ok (null (qlot-entry-ref ql))))
  (let ((gh (parse-qlot-line "github fukamachi/sxql v0.1.0")))
    (ok (eq (qlot-entry-kind gh) :github))
    (ok (string= (qlot-entry-name gh) "fukamachi/sxql"))
    (ok (string= (qlot-entry-ref gh) "v0.1.0")))
  (ok (null (parse-qlot-line "dist ultralisp https://dist.ultralisp.org/")))
  (ok (null (parse-qlot-line "   # comment only"))))

(deftest read-qlfile-and-sync-dispatch
  (let* ((path (merge-pathnames (format nil "cl-repo-qlfile-test-~a.txt" (get-universal-time))
                                (uiop:temporary-directory)))
         (installed nil)
         (source-entries nil))
    (unwind-protect
         (progn
           (with-open-file (stream path :direction :output :if-exists :supersede)
             (format stream "ql alexandria~%")
             (format stream "github fukamachi/sxql main~%"))
           (let ((entries (read-qlfile path)))
             (ok (= (length entries) 2)))
           (let ((orig (symbol-function 'cl-repository-client/commands::cmd-install)))
             (unwind-protect
                  (progn
                    (setf (symbol-function 'cl-repository-client/commands::cmd-install)
                          (lambda (reference &key registry-url namespace)
                            (declare (ignore registry-url namespace))
                            (push reference installed)))
                    (cmd-sync-qlot
                     :qlfile-path path
                     :source-handler (lambda (entry) (push entry source-entries))))
               (setf (symbol-function 'cl-repository-client/commands::cmd-install) orig)))
           (ok (equal installed '("alexandria")))
           (ok (= (length source-entries) 1))
           (ok (eq (qlot-entry-kind (first source-entries)) :github)))
      (when (probe-file path)
        (delete-file path)))))

(deftest read-qlfile-lock-and-plan-ordering
  (let* ((path (merge-pathnames (format nil "cl-repo-qlfile-lock-test-~a.txt" (get-universal-time))
                                (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (stream path :direction :output :if-exists :supersede)
             (format stream "github fukamachi/sxql abcdef~%")
             (format stream "ql alexandria 1.0.1~%")
             (format stream "ql alexandria~%")
             (format stream "git https://github.com/edicl/cl-ppcre.git 7f00~%"))
           (let* ((entries (read-qlfile-lock path))
                  (plan (build-qlot-sync-plan entries)))
             (ok (= (length entries) 4))
             (ok (= (length plan) 3))
             (ok (eq (qlot-entry-kind (first plan)) :ql))
             (ok (string= (qlot-entry-name (first plan)) "alexandria"))
             (ok (eq (qlot-entry-kind (second plan)) :github))
             (ok (eq (qlot-entry-kind (third plan)) :git))))
      (when (probe-file path)
        (delete-file path)))))

(deftest qlfile-path-inference-from-parent-directory
  (let* ((root (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-qlot-infer-~a/" (get-universal-time))
                                 (uiop:temporary-directory))))
         (nested (merge-pathnames "a/b/" root)))
    (unwind-protect
         (progn
           (ensure-directories-exist nested)
           (with-open-file (stream (merge-pathnames "qlfile" root)
                                   :direction :output :if-exists :supersede)
             (format stream "ql alexandria~%"))
           (with-open-file (stream (merge-pathnames "qlfile.lock" root)
                                   :direction :output :if-exists :supersede)
             (format stream "ql alexandria 1.0.1~%"))
           (uiop:with-current-directory (nested)
             (let ((entries (read-qlfile)))
               (ok (= (length entries) 1))
               (ok (string= (qlot-entry-name (first entries)) "alexandria")))
             (multiple-value-bind (entries resolved-path)
                 (read-qlfile-with-path)
               (ok (= (length entries) 1))
               (ok (search "/qlfile" (namestring resolved-path))))
             (let ((lock-entries (read-qlfile-lock)))
               (ok (= (length lock-entries) 1))
               (ok (string= (qlot-entry-ref (first lock-entries)) "1.0.1")))
             (multiple-value-bind (lock-entries resolved-lock-path)
                 (read-qlfile-lock-with-path)
               (ok (= (length lock-entries) 1))
               (ok (search "/qlfile.lock" (namestring resolved-lock-path))))))
      (when (probe-file root)
        (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))))

(deftest cmd-sync-qlot-uses-lock-entries-when-requested
  (let* ((qlfile-path (merge-pathnames (format nil "cl-repo-qlfile-~a.txt" (get-universal-time))
                                       (uiop:temporary-directory)))
         (lock-path (merge-pathnames (format nil "cl-repo-qlfile-lock-~a.txt" (get-universal-time))
                                     (uiop:temporary-directory)))
         (installed nil))
    (unwind-protect
         (progn
           (with-open-file (stream qlfile-path :direction :output :if-exists :supersede)
             (format stream "ql split-sequence~%"))
           (with-open-file (stream lock-path :direction :output :if-exists :supersede)
             (format stream "ql alexandria 1.0.1~%"))
           (let ((orig (symbol-function 'cl-repository-client/commands::cmd-install)))
             (unwind-protect
                  (progn
                    (setf (symbol-function 'cl-repository-client/commands::cmd-install)
                          (lambda (reference &key registry-url namespace)
                            (declare (ignore registry-url namespace))
                            (push reference installed)))
                    (cmd-sync-qlot :qlfile-path qlfile-path
                                   :qlfile-lock-path lock-path
                                   :use-lock t))
               (setf (symbol-function 'cl-repository-client/commands::cmd-install) orig)))
           (ok (equal installed '("alexandria:1.0.1"))))
      (when (probe-file qlfile-path)
        (delete-file qlfile-path))
      (when (probe-file lock-path)
        (delete-file lock-path)))))

(deftest version-selection-prefers-numeric-order
  (ok (string= (select-preferred-version '("v1.0.0" "v1.2.0" "v1.10.0")) "v1.10.0"))
  (ok (string= (select-preferred-version '("20240101" "20231231" "20250202")) "20250202")))
