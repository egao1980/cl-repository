(defpackage :cl-repository-client/tests/asd-rewrite-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/asd-rewrite #:cmd-add-overlay #:read-system-overlays))
(in-package :cl-repository-client/tests/asd-rewrite-test)

(defun read-forms (path)
  (with-open-file (in path)
    (let ((*read-eval* nil))
      (loop for form = (read in nil :eof) until (eq form :eof) collect form))))

(deftest add-overlay-edits-asd-and-replaces-same-key
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "cl-repo-asd-~a/" (get-universal-time))
                                (uiop:temporary-directory))))
         (asd (merge-pathnames "demo.asd" dir)))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (out asd :direction :output :if-exists :supersede)
             (write '(defsystem "demo"
                      :version "1.0.0"
                      :depends-on ("alexandria")
                      :components ((:file "demo")))
                    :stream out :case :downcase))
           (cmd-add-overlay dir :os "linux" :arch "amd64")
           (cmd-add-overlay dir :lisp "ecl")
           (cmd-add-overlay dir :os "linux" :arch "amd64")
           (let* ((form (first (read-forms asd)))
                  (overlays (read-system-overlays dir :system "demo")))
             (ok (equal (getf (cddr form) :depends-on) '("alexandria")))
             (ok (= (length overlays) 2))
             (let ((linux (find "linux-amd64" overlays :key (lambda (o) (getf o :name)) :test #'string=))
                   (ecl (find "ecl" overlays :key (lambda (o) (getf o :name)) :test #'string=)))
               (ok linux)
               (ok ecl)
               (ok (null (getf (getf ecl :platform) :os)))
               (ok (string= (getf (getf ecl :platform) :lisp) "ecl")))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
