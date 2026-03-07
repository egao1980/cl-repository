(defpackage :cl-repository-client/digest-cache
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
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
  (let ((path (cache-file-path)))
    (when (probe-file path)
      (handler-case
          (with-open-file (s path :direction :input)
            (let ((data (read s nil nil)))
              (when (listp data)
                (clrhash *installed-digests*)
                (dolist (pair data)
                  (setf (gethash (car pair) *installed-digests*) (cdr pair))))))
        (error () nil)))))

(defun save-digest-cache ()
  "Persist digest cache to disk."
  (let ((path (cache-file-path)))
    (ensure-directories-exist path)
    (handler-case
        (with-open-file (s path :direction :output :if-exists :supersede)
          (let ((entries nil))
            (maphash (lambda (k v) (push (cons k v) entries)) *installed-digests*)
            (write entries :stream s :readably t)))
      (error () nil))))
