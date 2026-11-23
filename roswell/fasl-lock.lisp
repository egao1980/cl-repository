;;;; One fasl root, many images: a compile holds its fasl's lock.
;;;;
;;;; Loaded as source, once ASDF is loaded, into every image cl-repo starts:
;;;; the client (cl-repo.ros), the fresh image of `cl-repo test` and the Lisp
;;;; of `cl-repo run` / `cl-repo ros`. They share one fasl root,
;;;; <XDG_CACHE_HOME>/common-lisp/cl-repo/<impl>/, and two of them compiling
;;;; the same file there killed each other's load (cl-repository#162). UIOP's
;;;; COMPILE-FILE* deletes the fasl, renames its staging file over it, then
;;;; takes its TRUENAME, and ASDF loads it. Another image's delete lands in
;;;; between: "Couldn't load …fasl: file does not exist", "Failed to find the
;;;; TRUENAME". The staging names are not the cause: GET-TEMPORARY-FILE
;;;; creates each one exclusively.
;;;;
;;;; Here each compile-op of a Lisp file holds an exclusive flock(2) on
;;;; <fasl>.lock beside its fasl, and each load-op a shared one, so no image
;;;; opens a fasl while another replaces it. The kernel drops a lock with its
;;;; process. SBCL off Windows only; on other Lisps the methods run their
;;;; operation unlocked. Nothing is printed: stdout of `cl-repo run` is the
;;;; command's (#130).

(defpackage :cl-repo-fasl-lock
  (:use :cl)
  (:export #:call-with-fasl-lock #:fasl-lock-file))

(in-package :cl-repo-fasl-lock)

(defvar *held* '()
  "Lock files this thread holds, innermost first. A nested compile or load of
   the same fasl takes no second lock: flock would make it wait on the first.")

#+(and sbcl (not win32))
(defun flock (fd operation)
  "flock(2) FD with OPERATION (1 shared, 2 exclusive), again when a signal
   interrupts the wait. → T when the lock is taken."
  (loop
    (when (zerop (sb-alien:alien-funcall
                  (sb-alien:extern-alien "flock" (function sb-alien:int sb-alien:int sb-alien:int))
                  fd operation))
      (return t))
    (unless (= (sb-alien:get-errno) sb-unix:eintr)
      (return nil))))

(defun fasl-lock-file (fasl)
  "The lock file of FASL: <FASL>.lock, beside it."
  (let ((file (uiop:physicalize-pathname fasl)))
    (make-pathname :name (file-namestring file) :type "lock" :version nil :defaults file)))

(defun call-with-fasl-lock (fasl exclusive thunk)
  "Call THUNK holding a flock(2) on FASL's lock file (FASL-LOCK-FILE):
   exclusive when EXCLUSIVE, else shared. THUNK runs unlocked when FASL is
   NIL, on a Lisp without flock, when the lock file cannot be opened (a
   read-only output directory) or when it cannot be locked (a file system
   without flock)."
  #-(and sbcl (not win32))
  (declare (ignore fasl exclusive))
  #-(and sbcl (not win32))
  (funcall thunk)
  #+(and sbcl (not win32))
  (let ((lock (and fasl (fasl-lock-file fasl))))
    (if (or (null lock) (member lock *held* :test #'equal))
        (funcall thunk)
        (let ((stream (handler-case
                          (progn (ensure-directories-exist lock)
                                 (open lock :direction :output :if-exists :append
                                            :if-does-not-exist :create))
                        (file-error () nil))))
          (if (null stream)
              (funcall thunk)
              (unwind-protect
                   (let ((*held* (cons lock *held*)))
                     (flock (sb-sys:fd-stream-fd stream) (if exclusive 2 1))
                     (funcall thunk))
                ;; closing the descriptor releases the lock
                (close stream)))))))

(defmethod asdf:perform :around ((o asdf:compile-op) (c asdf:cl-source-file))
  "Compile C while no other image compiles or loads its fasl."
  (call-with-fasl-lock (first (asdf:output-files o c)) t (lambda () (call-next-method))))

(defmethod asdf:perform :around ((o asdf:load-op) (c asdf:cl-source-file))
  "Load C's fasl while no other image replaces it."
  (call-with-fasl-lock (first (asdf:input-files o c)) nil (lambda () (call-next-method))))
