(defpackage :cl-repository-client/lockfile
  (:use :cl)
  (:export #:lockfile-entry
           #:lockfile-entry-system
           #:lockfile-entry-version
           #:lockfile-entry-index-digest
           #:lockfile-entry-source-digest
           #:lockfile-entry-overlay-digest
           #:lockfile-entry-registry
           #:read-lockfile
           #:write-lockfile
           #:add-lockfile-entry))
(in-package :cl-repository-client/lockfile)

(defclass lockfile-entry ()
  ((system :type string :initarg :system :accessor lockfile-entry-system)
   (version :type string :initarg :version :accessor lockfile-entry-version)
   (index-digest :type string :initarg :index-digest :accessor lockfile-entry-index-digest)
   (source-digest :type (or null string) :initarg :source-digest
                  :accessor lockfile-entry-source-digest :initform nil)
   (overlay-digest :type (or null string) :initarg :overlay-digest
                   :accessor lockfile-entry-overlay-digest :initform nil)
   (registry :type string :initarg :registry :accessor lockfile-entry-registry)))

(defun lockfile-path (&optional (directory (uiop:getcwd)))
  (merge-pathnames "cl-repo.lock" directory))

(defun entry-to-plist (entry)
  (let ((plist (list :system (lockfile-entry-system entry)
                     :version (lockfile-entry-version entry)
                     :index-digest (lockfile-entry-index-digest entry)
                     :registry (lockfile-entry-registry entry))))
    (when (lockfile-entry-source-digest entry)
      (setf plist (append plist (list :source-digest (lockfile-entry-source-digest entry)))))
    (when (lockfile-entry-overlay-digest entry)
      (setf plist (append plist (list :overlay-digest (lockfile-entry-overlay-digest entry)))))
    plist))

(defun plist-to-entry (plist)
  (make-instance 'lockfile-entry
                 :system (getf plist :system)
                 :version (getf plist :version)
                 :index-digest (getf plist :index-digest)
                 :source-digest (getf plist :source-digest)
                 :overlay-digest (getf plist :overlay-digest)
                 :registry (getf plist :registry)))

(defun read-lockfile (&optional (path (lockfile-path)))
  "Read a lockfile, returning a list of LOCKFILE-ENTRY objects."
  (if (probe-file path)
      (with-open-file (s path :direction :input)
        (let ((data (read s nil nil)))
          (mapcar #'plist-to-entry data)))
      nil))

(defun write-lockfile (entries &optional (path (lockfile-path)))
  "Write a lockfile from a list of LOCKFILE-ENTRY objects."
  (with-open-file (s path :direction :output :if-exists :supersede)
    (format s ";;; cl-repo.lock -- auto-generated, do not edit~%")
    (let ((*print-case* :downcase))
      (prin1 (mapcar #'entry-to-plist entries) s))
    (terpri s)))

(defun add-lockfile-entry (entry &optional (path (lockfile-path)))
  "Add or update a lockfile entry."
  (let* ((entries (read-lockfile path))
         (existing (find (lockfile-entry-system entry) entries
                         :key #'lockfile-entry-system :test #'string=))
         (new-entries (if existing
                         (substitute entry existing entries)
                         (append entries (list entry)))))
    (write-lockfile new-entries path)
    new-entries))
