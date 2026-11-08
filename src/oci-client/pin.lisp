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

(defpackage :cl-oci-client/pin
  (:use :cl)
  (:export #:with-loaded-systems-pinned
           #:loaded-system-files))
(in-package :cl-oci-client/pin)

(defvar *pinned* nil
  "While pinned: hash table of loaded system name → its .asd pathname.")

(defun loaded-system-files ()
  "Hash table of every loaded system's name → the .asd it was loaded from."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (name (asdf:already-loaded-systems) table)
      (let* ((sys (asdf:registered-system name))
             (file (and sys (asdf:system-source-file sys))))
        (when file
          (setf (gethash name table) file))))))

(defun pinned-system-search (name)
  "ASDF search function: the .asd a pinned NAME was loaded from."
  (when *pinned*
    (values (gethash name *pinned*))))

(pushnew 'pinned-system-search asdf:*system-definition-search-functions*)

(defun call-with-loaded-systems-pinned (thunk)
  (if *pinned*
      (funcall thunk)
      (let ((*pinned* (loaded-system-files)))
        (funcall thunk))))

(defmacro with-loaded-systems-pinned (() &body body)
  "Run BODY with every loaded system resolving to the .asd it was loaded from."
  `(call-with-loaded-systems-pinned (lambda () ,@body)))
