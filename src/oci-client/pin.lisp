;;;; Keep the running client's own systems where they were loaded from.
;;;;
;;;; cl-repo prepends the install tree (systems-root) to the ASDF registry once
;;;; it starts working on a project. A LOAD-SYSTEM inside the client after that
;;;; — http-protocol probing a Content-Encoding backend, the packager loading
;;;; for a publish — can resolve a system the client already runs (http-protocol
;;;; 0.3.9) to an older copy in the install tree (0.3.0) and recompile it over
;;;; the live code. WITH-LOADED-SYSTEMS-PINNED makes every loaded system resolve
;;;; to the .asd it was loaded from while BODY runs; systems not yet loaded
;;;; resolve as usual.
;;;;
;;;; When the registry offers a newer version of a pinned system (a project
;;;; locks http-protocol 0.3.11, the client runs 0.3.10) the loaded copy still
;;;; wins, and LOADED-SYSTEM-SHADOWS-NEWER is warned once per system so the
;;;; project's code does not silently run against the older one.

(defpackage :cl-oci-client/pin
  (:use :cl)
  (:export #:with-loaded-systems-pinned
           #:loaded-system-files
           #:pinned-system-p
           #:loaded-system-shadows-newer
           #:shadowed-system-name
           #:shadowed-loaded-version
           #:shadowed-newer-version
           #:shadowed-newer-file))
(in-package :cl-oci-client/pin)

(defvar *pinned* nil
  "While pinned: hash table of loaded system name → its .asd pathname.")

(defun under-any-p (file directories)
  (some (lambda (dir)
          (uiop:subpathp (or (probe-file file) file)
                         (uiop:ensure-directory-pathname (or (probe-file dir) dir))))
        directories))

(defun loaded-system-files (&key except)
  "Hash table of every loaded system's name → the .asd it was loaded from,
   leaving out systems whose .asd lies under one of the EXCEPT directories."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (name (asdf:already-loaded-systems) table)
      (let* ((sys (asdf:registered-system name))
             (file (and sys (asdf:system-source-file sys))))
        (when (and file (not (under-any-p file except)))
          (setf (gethash name table) file))))))

(defvar *checked* nil
  "While pinned: names already compared against the rest of the registry.")

(define-condition loaded-system-shadows-newer (warning)
  ((name :initarg :name :reader shadowed-system-name)
   (loaded-version :initarg :loaded-version :reader shadowed-loaded-version)
   (loaded-file :initarg :loaded-file :reader shadowed-loaded-file)
   (newer-version :initarg :newer-version :reader shadowed-newer-version)
   (newer-file :initarg :newer-file :reader shadowed-newer-file))
  (:report (lambda (c s)
             (format s "cl-repo: ~A ~A stays loaded from ~A; the registry also has ~A at ~A, ~
                        which this image will not load. Code that needs ~A runs against the ~
                        older copy: upgrade the client or load the project in a fresh image."
                     (shadowed-system-name c) (shadowed-loaded-version c)
                     (shadowed-loaded-file c) (shadowed-newer-version c)
                     (shadowed-newer-file c) (shadowed-newer-version c)))))

(defun asd-literal-version (file name)
  "The literal :VERSION string of system NAME's DEFSYSTEM in FILE, read without
   evaluating anything, or NIL (no such form, a computed version, or a read error)."
  (let ((*read-eval* nil)
        (*package* (make-package (gensym "PIN-ASD-") :use '(:cl))))
    (unwind-protect
         (ignore-errors
          (with-open-file (in file :external-format :utf-8)
            (loop for form = (read in nil in)
                  until (eq form in)
                  do (when (and (consp form) (symbolp (first form))
                                (string= "DEFSYSTEM" (symbol-name (first form)))
                                (or (stringp (second form)) (symbolp (second form)))
                                (string-equal name (string (second form))))
                       (let ((version (getf (cddr form) :version)))
                         (return (and (stringp version) version)))))))
      (delete-package *package*))))

(defun unpinned-system-file (name)
  "The .asd NAME would resolve to without the pin."
  (dolist (fn asdf:*system-definition-search-functions*)
    (unless (eq fn 'pinned-system-search)
      (let ((found (ignore-errors (funcall fn name))))
        (when (pathnamep found) (return found))))))

(defun check-shadowing (name loaded-file)
  "Warn once per pin scope when the registry has a newer NAME than the loaded one."
  (unless (gethash name *checked*)
    (setf (gethash name *checked*) t)
    (let* ((sys (asdf:registered-system name))
           (loaded (and sys (asdf:component-version sys)))
           (other (unpinned-system-file name))
           (newer (and loaded other
                       (not (uiop:pathname-equal (truename other) (truename loaded-file)))
                       (asd-literal-version other name))))
      (when (and newer
                 (uiop:parse-version loaded nil) (uiop:parse-version newer nil)
                 (uiop:version< loaded newer))
        (warn 'loaded-system-shadows-newer
              :name name :loaded-version loaded :loaded-file loaded-file
              :newer-version newer :newer-file other)))))

(defun pinned-system-search (name)
  "ASDF search function: the .asd a pinned NAME was loaded from."
  (when *pinned*
    (let ((file (gethash name *pinned*)))
      (when file
        (ignore-errors (check-shadowing name file)))
      file)))

(pushnew 'pinned-system-search asdf:*system-definition-search-functions*)

(defun pinned-system-p (name)
  "True while NAME is pinned: loaded in this image and outside the checkout."
  (and *pinned* (nth-value 1 (gethash (string-downcase (string name)) *pinned*))))

(defun call-with-loaded-systems-pinned (thunk &key except)
  (if *pinned*
      (funcall thunk)
      (let ((*pinned* (loaded-system-files :except except))
            (*checked* (make-hash-table :test #'equal)))
        (funcall thunk))))

(defmacro with-loaded-systems-pinned ((&key except) &body body)
  "Run BODY with every loaded system resolving to the .asd it was loaded from.
   Systems under the EXCEPT directories (a project checkout) are not pinned."
  `(call-with-loaded-systems-pinned (lambda () ,@body) :except ,except))
