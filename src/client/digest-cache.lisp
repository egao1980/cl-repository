(defpackage :cl-repository-client/digest-cache
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:import-from :cl-repository-client/atomic-file #:with-atomic-output-file #:read-sexp-file)
  (:export #:*installed-digests*
           #:digest-already-installed-p
           #:record-installed-digest
           #:load-digest-cache
           #:save-digest-cache))
(in-package :cl-repository-client/digest-cache)

(defvar *installed-digests* (make-hash-table :test 'equal)
  "Maps manifest digest string -> install path for dedup across load-system calls.")

(defun cache-file-path ()
  (merge-pathnames ".digest-cache.sexp" (systems-root)))

(defun digest-already-installed-p (digest)
  "Return install path if DIGEST was already installed, NIL otherwise."
  (gethash digest *installed-digests*))

(defun record-installed-digest (digest path)
  "Record that DIGEST was installed at PATH."
  (setf (gethash digest *installed-digests*) (namestring path))
  (save-digest-cache))

(defun load-digest-cache ()
  "Load digest cache from disk."
  (handler-case
      (let ((data (read-sexp-file (cache-file-path))))
        (when (listp data)
          (clrhash *installed-digests*)
          (dolist (pair data)
            (setf (gethash (car pair) *installed-digests*) (cdr pair)))))
    (error () nil)))

(defun save-digest-cache ()
  "Persist digest cache to disk."
  (let ((path (cache-file-path)))
    (ensure-directories-exist path)
    (handler-case
        (with-atomic-output-file (s path)
          (let ((entries nil))
            (maphash (lambda (k v) (push (cons k v) entries)) *installed-digests*)
            (write entries :stream s :readably t)))
      (error () nil))))
