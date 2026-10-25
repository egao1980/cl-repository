(defpackage :cl-repository-client/tests/asd-rewrite-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/asd-rewrite
                #:overlay-key
                #:add-overlay-entry))
(in-package :cl-repository-client/tests/asd-rewrite-test)

(defun make-temp-dir ()
  (let ((dir (merge-pathnames
              (format nil "cl-repo-asd-rewrite-~a-~a/"
                      (get-universal-time)
                      (random 1000000000 (make-random-state t)))
              (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    dir))

(defun read-defsystem (path)
  (let ((*read-eval* nil)
        (*package* (find-package :cl-user)))
    (with-open-file (in path :direction :input)
      (read in))))

(defun overlays-of (path)
  (getf (getf (getf (cddr (read-defsystem path)) :properties) :cl-repo) :overlays))

(deftest overlay-key-joins-present-parts
  (ok (equal "ecl" (overlay-key :lisp "ecl")))
  (ok (equal "linux-amd64" (overlay-key :os "linux" :arch "amd64")))
  (ok (equal "linux-amd64-ecl" (overlay-key :os "linux" :arch "amd64" :lisp "ecl")))
  (ok (equal "linux-ecl" (overlay-key :os "linux" :lisp "ecl")))
  (ok (equal "" (overlay-key))))

(deftest add-overlay-entry-layers-and-replace
  (let* ((dir (make-temp-dir))
         (path (merge-pathnames "vanilla-app.asd" dir)))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :supersede)
             (write-string "(defsystem \"vanilla-app\" :version \"0.1.0\" :depends-on (\"alexandria\") :components nil)"
                           out))
           (add-overlay-entry path :os "linux" :arch "amd64")
           (let* ((form (read-defsystem path))
                  (overlays (overlays-of path))
                  (linux (first overlays))
                  (layers (getf linux :layers)))
             (ok (equal "vanilla-app" (second form)))
             (ok (equal "0.1.0" (getf (cddr form) :version)))
             (ok (equal '("alexandria") (getf (cddr form) :depends-on)))
             (ok (equal "linux-amd64" (getf linux :name)))
             (ok (equal '(:os "linux" :arch "amd64") (getf linux :platform)))
             (ok (= 2 (length layers)))
             (ok (equal '(:role "native-library" :files (("lib/linux-amd64/" . "lib/")))
                        (first layers)))
             (ok (equal '(:role "cffi-grovel-output" :files (("grovel/linux-amd64/" . "grovel/")))
                        (second layers))))
           (add-overlay-entry path :lisp "ecl")
           (let* ((overlays (overlays-of path))
                  (ecl (find "ecl" overlays :key (lambda (overlay) (getf overlay :name)) :test #'equal)))
             (ok (= 2 (length overlays)))
             (ok (equal "linux-amd64" (getf (first overlays) :name)))
             (ok ecl)
             (ok (equal '(:lisp "ecl") (getf ecl :platform)))
             (ok (null (getf (getf ecl :platform) :os)))
             (ok (null (getf (getf ecl :platform) :arch)))
             (ok (= 1 (length (getf ecl :layers))))
             (ok (equal '(:role "cffi-grovel-output" :files (("grovel/ecl/" . "grovel/")))
                        (first (getf ecl :layers)))))
           (add-overlay-entry path :lisp "ecl")
           (let ((overlays (overlays-of path)))
             (ok (= 2 (length overlays)))
             (ok (= 1 (count "ecl" overlays :key (lambda (overlay) (getf overlay :name)) :test #'equal)))
             (ok (= 1 (count "linux-amd64" overlays
                             :key (lambda (overlay) (getf overlay :name)) :test #'equal)))))
      (uiop:delete-directory-tree dir :validate t))))

(deftest add-overlay-entry-custom-name-keeps-key-dirs
  (let* ((dir (make-temp-dir))
         (path (merge-pathnames "named.asd" dir)))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :if-exists :supersede)
             (write-string "(defsystem \"named\" :components nil)" out))
           (add-overlay-entry path :name "custom" :lisp "ecl")
           (let ((overlay (first (overlays-of path))))
             (ok (equal "custom" (getf overlay :name)))
             (ok (equal '(:lisp "ecl") (getf overlay :platform)))
             (ok (equal '(:role "cffi-grovel-output" :files (("grovel/ecl/" . "grovel/")))
                        (first (getf overlay :layers))))))
      (uiop:delete-directory-tree dir :validate t))))
