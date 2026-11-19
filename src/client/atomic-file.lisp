(defpackage :cl-repository-client/atomic-file
  (:use :cl)
  (:export #:with-atomic-output-file
           #:read-sexp-file
           #:temp-file-name-p
           #:remove-stale-temp-files))
(in-package :cl-repository-client/atomic-file)

(defvar *stale-temp-age* 3600
  "Seconds after which a temp file of the current naming scheme counts as left
   by a dead writer. A younger one may belong to a concurrent install.")

(defun temp-file-name (path)
  "The temp file a write of PATH goes through, next to PATH.
   The temp keeps PATH's type, the marker goes in the name. RENAME-FILE merges
   the new name with the old one, so a type-less target (LICENSE, VERSION)
   given a temp named LICENSE.tmp-N took the type \"tmp-N\": the rename went
   nowhere, the file was never written, and the temp stayed (cl-repo
   0.27.4-0.27.5)."
  (make-pathname :name (format nil ".~a.tmp-~d-~d"
                               (pathname-name path)
                               (get-universal-time)
                               (random 1000000 (make-random-state t)))
                 :type (pathname-type path)
                 :defaults path))

(defun call-with-atomic-output-file (path thunk &key (element-type 'character))
  "Call THUNK with an output stream to a temp file, then rename onto PATH.
   Prevents concurrent writers from corrupting PATH and readers from seeing
   partial writes. The rename gives PATH a new inode: a process that has the
   old file open or mapped (a loaded shared library) keeps its contents.
   When THUNK or the rename does not complete, the temp is deleted."
  (let* ((path (pathname path))
         (temp (temp-file-name path))
         (done nil))
    (unwind-protect
         (progn
           (with-open-file (s temp :direction :output :if-exists :supersede
                                   :element-type element-type)
             (funcall thunk s))
           (uiop:rename-file-overwriting-target temp path)
           (setf done t))
      (unless done
        (ignore-errors (delete-file temp))))))

(defmacro with-atomic-output-file ((stream path &key (element-type ''character)) &body body)
  "Like WITH-OPEN-FILE for output, but writes atomically via temp file + rename."
  `(call-with-atomic-output-file ,path (lambda (,stream) ,@body)
                                 :element-type ,element-type))

(defun %digits-p (string start end)
  (and (< start end)
       (loop for i from start below end always (digit-char-p (char string i)))))

(defun %temp-marker (string)
  "When STRING ends in .tmp-<time>-<random>, the position of \".tmp-\" and
   the time; else NIL."
  (let ((pos (search ".tmp-" string :from-end t)))
    (when pos
      (let ((dash (position #\- string :start (+ pos 5))))
        (when (and dash
                   (%digits-p string (+ pos 5) dash)
                   (%digits-p string (1+ dash) (length string)))
          (values pos (parse-integer string :start (+ pos 5) :end dash)))))))

(defun temp-file-name-p (filename &key (now (get-universal-time)) (age *stale-temp-age*))
  "True when FILENAME (name and type, no directory) is a temp file of
   WITH-ATOMIC-OUTPUT-FILE older than AGE seconds, which no writer will rename
   any more. Both schemes count: <file>.tmp-<time>-<n> (cl-repo 0.27.4-0.27.5,
   whose rename never happened for a type-less LICENSE) and the current
   .<name>.tmp-<time>-<n>[.<type>] (its writer died before deleting it).
   A younger temp may belong to a concurrent install and is kept."
  (let ((time (or (nth-value 1 (%temp-marker filename))
                  ;; the current scheme keeps the target's type after the marker
                  (let ((dot (position #\. filename :from-end t)))
                    (and dot (nth-value 1 (%temp-marker (subseq filename 0 dot))))))))
    (and time (> (- now time) age))))

(defun remove-stale-temp-files (directory)
  "Delete the temp files TEMP-FILE-NAME-P recognises under DIRECTORY,
   recursively. Returns the number deleted."
  (let ((count 0))
    (labels ((walk (dir)
               (dolist (file (uiop:directory-files dir))
                 (when (temp-file-name-p (file-namestring file))
                   (when (ignore-errors (delete-file file))
                     (incf count))))
               (dolist (sub (uiop:subdirectories dir))
                 (walk sub))))
      (when (probe-file directory)
        (walk (uiop:ensure-directory-pathname directory))))
    count))

(defun read-sexp-file (path)
  "READ the first form from PATH with *READ-EVAL* disabled.
   Returns NIL if the file is missing or empty.
   Use for local data files (lockfiles, caches, manifests) whose contents
   must never execute code via #. reader macros."
  (when (probe-file path)
    (with-open-file (s path :direction :input)
      (let ((*read-eval* nil))
        (read s nil nil)))))
