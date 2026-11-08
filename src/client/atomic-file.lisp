(defpackage :cl-repository-client/atomic-file
  (:use :cl)
  (:export #:with-atomic-output-file
           #:read-sexp-file))
(in-package :cl-repository-client/atomic-file)

(defun call-with-atomic-output-file (path thunk &key (element-type 'character))
  "Call THUNK with an output stream to a temp file, then rename onto PATH.
   Prevents concurrent writers from corrupting PATH and readers from seeing
   partial writes. The rename gives PATH a new inode: a process that has the
   old file open or mapped (a loaded shared library) keeps its contents."
  (let* ((path (pathname path))
         ;; The temp keeps PATH's type, the marker goes in the name. RENAME-FILE
         ;; merges the new name with the old one, so a type-less target
         ;; (LICENSE, VERSION) given a temp named LICENSE.tmp-N took the type
         ;; "tmp-N": the rename went nowhere, the file was never written, and
         ;; the temp stayed (cl-repo 0.27.4-0.27.5).
         (temp (make-pathname :name (format nil ".~a.tmp-~d-~d"
                                            (pathname-name path)
                                            (get-universal-time)
                                            (random 1000000 (make-random-state t)))
                              :type (pathname-type path)
                              :defaults path)))
    (with-open-file (s temp :direction :output :if-exists :supersede
                            :element-type element-type)
      (funcall thunk s))
    (uiop:rename-file-overwriting-target temp path)))

(defmacro with-atomic-output-file ((stream path &key (element-type ''character)) &body body)
  "Like WITH-OPEN-FILE for output, but writes atomically via temp file + rename."
  `(call-with-atomic-output-file ,path (lambda (,stream) ,@body)
                                 :element-type ,element-type))

(defun read-sexp-file (path)
  "READ the first form from PATH with *READ-EVAL* disabled.
   Returns NIL if the file is missing or empty.
   Use for local data files (lockfiles, caches, manifests) whose contents
   must never execute code via #. reader macros."
  (when (probe-file path)
    (with-open-file (s path :direction :input)
      (let ((*read-eval* nil))
        (read s nil nil)))))
