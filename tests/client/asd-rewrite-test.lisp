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

(deftest add-overlay-preserves-formatting
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "cl-repo-fmt-~a/" (random 100000000))
                                (uiop:temporary-directory))))
         (asd (merge-pathnames "demo.asd" dir))
         (original ";;;; demo.asd — comments and layout must survive
(defsystem \"demo\"
  :version \"1.0.0\"
  #+sbcl :depends-on #+sbcl (\"sb-posix\") ; reader conditional kept
  :components ((:file \"demo\")))

(defsystem \"demo/tests\"
  :depends-on (\"demo\")) ; never gets the overlay
"))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (out asd :direction :output :if-exists :supersede)
             (write-string original out))
           (cmd-add-overlay dir :os "linux" :arch "amd64")
           (let ((text (uiop:read-file-string asd)))
             (ok (search ";;;; demo.asd — comments and layout must survive" text))
             (ok (search "#+sbcl :depends-on #+sbcl (\"sb-posix\") ; reader conditional kept" text))
             (ok (search "(defsystem \"demo/tests\"
  :depends-on (\"demo\")) ; never gets the overlay" text)
                 "the test system is untouched")
             (ok (= 1 (length (read-system-overlays dir :system "demo")))))
           ;; second run edits the :overlays value in place
           (cmd-add-overlay dir :os "darwin" :arch "arm64")
           (let ((text (uiop:read-file-string asd)))
             (ok (= 1 (count-matches ":cl-repo" text)) "one :cl-repo, edited in place")
             (ok (= 2 (length (read-system-overlays dir :system "demo"))))
             (ok (null (read-system-overlays dir :system "demo/tests")))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))

(defun count-matches (needle text)
  (loop for start = 0 then (+ at (length needle))
        for at = (search needle text :start2 start)
        while at count t))

(deftest add-overlay-into-existing-cl-repo
  (let* ((dir (uiop:ensure-directory-pathname
               (merge-pathnames (format nil "cl-repo-fmt2-~a/" (random 100000000))
                                (uiop:temporary-directory))))
         (asd (merge-pathnames "demo.asd" dir)))
    (ensure-directories-exist dir)
    (unwind-protect
         (progn
           (with-open-file (out asd :direction :output :if-exists :supersede)
             (write-string "(defsystem \"demo\"
  :properties (:cl-repo (:provides (\"demo\")  ; keep
                         :cffi-libraries (\"libdemo\"))))
" out))
           (cmd-add-overlay dir :os "linux" :arch "amd64")
           (let ((text (uiop:read-file-string asd)))
             (ok (search ":provides (\"demo\")  ; keep" text) "sibling keys and comments kept")
             (ok (= 1 (length (read-system-overlays dir :system "demo"))))))
      (uiop:delete-directory-tree dir :validate t :if-does-not-exist :ignore))))
