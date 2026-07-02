(defpackage :cl-repository-client/atomic-file
  (:use :cl)
  (:export #:with-atomic-output-file
           #:read-sexp-file))
(in-package :cl-repository-client/atomic-file)

(defun call-with-atomic-output-file (path thunk)
  "Call THUNK with an output stream to a temp file, then rename onto PATH.
   Prevents concurrent writers from corrupting PATH and readers from seeing
   partial writes."
  (let* ((path (pathname path))
         (temp (merge-pathnames (format nil "~a.tmp-~d-~d"
                                        (file-namestring path)
                                        (get-universal-time)
                                        (random 1000000 (make-random-state t)))
                                path)))
    (with-open-file (s temp :direction :output :if-exists :supersede)
      (funcall thunk s))
    (uiop:rename-file-overwriting-target temp path)))

(defmacro with-atomic-output-file ((stream path) &body body)
  "Like WITH-OPEN-FILE for output, but writes atomically via temp file + rename."
  `(call-with-atomic-output-file ,path (lambda (,stream) ,@body)))

(defun read-sexp-file (path)
  "READ the first form from PATH with *READ-EVAL* disabled.
   Returns NIL if the file is missing or empty.
   Use for local data files (lockfiles, caches, manifests) whose contents
   must never execute code via #. reader macros."
  (when (probe-file path)
    (with-open-file (s path :direction :input)
      (let ((*read-eval* nil))
        (read s nil nil)))))
