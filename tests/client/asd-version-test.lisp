(defpackage :cl-repository-client/tests/asd-version-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/asd-version
                #:bump-version #:read-asd-version #:write-asd-version #:cmd-version #:version-error))
(in-package :cl-repository-client/tests/asd-version-test)

(defparameter *asd*
  ";;;; demo.asd — hand formatted; this comment must survive
(defsystem \"demo\"
  :description \"Says :version \\\"9.9\\\" in a docstring\"   ; not the version
  :version \"1.2.3\"
  #+sbcl :depends-on #+sbcl (\"sb-posix\")
  :components ((:file \"demo\")))

#| a block comment with (defsystem \"demo\" :version \"0.0.1\") |#
(defsystem \"demo/tests\"
  :version \"1.2.3\"
  :depends-on (\"demo\" \"rove\"))
")

(defmacro with-asd ((dir &optional (text '*asd*)) &body body)
  `(let ((,dir (uiop:ensure-directory-pathname
                (merge-pathnames (format nil "cl-repo-ver-~a/" (random 100000000))
                                 (uiop:temporary-directory)))))
     (ensure-directories-exist ,dir)
     (unwind-protect
          (progn
            (with-open-file (s (merge-pathnames "demo.asd" ,dir) :direction :output :if-exists :supersede)
              (write-string ,text s))
            ,@body)
       (uiop:delete-directory-tree ,dir :validate t :if-does-not-exist :ignore))))

(defun asd-text (dir) (uiop:read-file-string (merge-pathnames "demo.asd" dir)))

(deftest-parametrize bumps
    ((version part expected)
     ("1.2.3"   :patch    "1.2.4")
     ("1.2.3"   :minor    "1.3.0")
     ("1.2.3"   :major    "2.0.0")
     ("1.2"     :patch    "1.2.1")
     ("1.2"     :minor    "1.3")
     ("3.5.9"   :revision "3.5.9.1")
     ("3.5.9.1" :revision "3.5.9.2")
     ("3.5.9.1" :patch    "3.5.10")
     ("0.1.0"   :minor    "0.2.0"))
  (ok (string= (bump-version version part) expected)))

(deftest bad-versions
  (ok (signals (bump-version "1.2.x" :patch) 'version-error))
  (ok (signals (bump-version "" :patch) 'version-error))
  (with-asd (dir)
    (ok (signals (write-asd-version dir "v1.0") 'version-error) "not ASDF version syntax")))

(deftest read-skips-docstrings-and-comments
  (with-asd (dir)
    (ok (string= (read-asd-version dir) "1.2.3"))))

(deftest write-changes-only-the-version
  (with-asd (dir)
    (write-asd-version dir "1.2.3.1")
    (ok (string= (asd-text dir)
                 (let ((at (search ":version \"1.2.3\"" *asd*)))
                   ;; the first real :version is the primary system's
                   (concatenate 'string (subseq *asd* 0 at) ":version \"1.2.3.1\""
                                (subseq *asd* (+ at (length ":version \"1.2.3\""))))))
        "byte for byte apart from the primary system's version")
    (ok (string= (read-asd-version dir :system "demo/tests") "1.2.3") "secondary untouched")
    (write-asd-version dir "2.0.0" :system "demo/tests")
    (ok (string= (read-asd-version dir :system "demo/tests") "2.0.0") "--system picks a defsystem")
    (ok (string= (read-asd-version dir) "1.2.3.1"))))

(deftest cmd-bump
  (with-asd (dir)
    (ok (string= (cmd-version dir :bump "revision") "1.2.3.1"))
    (ok (string= (cmd-version dir :bump "minor") "1.3.0"))
    (ok (string= (cmd-version dir) "1.3.0") "read")
    (ok (signals (cmd-version dir :bump "huge") 'version-error))
    (ok (signals (cmd-version dir :set "1.0" :bump "patch") 'version-error))))

(deftest insert-when-missing
  (with-asd (dir "(defsystem \"demo\" ; keep me
  :components ((:file \"demo\")))
")
    (ok (null (read-asd-version dir)))
    (write-asd-version dir "0.1.0")
    (ok (string= (read-asd-version dir) "0.1.0"))
    (ok (search "; keep me" (asd-text dir)) "comment kept")))

(deftest non-literal-version
  (with-asd (dir "(defsystem \"demo\" :version (:read-file-form \"version.sexp\"))
")
    (ok (signals (read-asd-version dir) 'version-error) "edit by hand")))
