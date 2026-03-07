(defpackage :cl-repository-ql-exporter/dist-parser
  (:use :cl)
  (:import-from :dexador)
  (:import-from :babel #:octets-to-string)
  (:export #:ql-dist
           #:ql-dist-name
           #:ql-dist-version
           #:ql-dist-system-index-url
           #:ql-dist-release-index-url
           #:ql-dist-archive-base-url
           #:ql-release
           #:ql-release-project
           #:ql-release-url
           #:ql-release-size
           #:ql-release-file-md5
           #:ql-release-content-sha1
           #:ql-release-prefix
           #:ql-release-system-files
           #:ql-system
           #:ql-system-project
           #:ql-system-system-file
           #:ql-system-system-name
           #:ql-system-dependencies
           #:parse-distinfo
           #:parse-releases
           #:parse-systems
           #:fetch-and-parse-dist))
(in-package :cl-repository-ql-exporter/dist-parser)

(defclass ql-dist ()
  ((name :type string :initarg :name :accessor ql-dist-name)
   (version :type string :initarg :version :accessor ql-dist-version)
   (system-index-url :type string :initarg :system-index-url :accessor ql-dist-system-index-url)
   (release-index-url :type string :initarg :release-index-url :accessor ql-dist-release-index-url)
   (archive-base-url :type string :initarg :archive-base-url :accessor ql-dist-archive-base-url)))

(defclass ql-release ()
  ((project :type string :initarg :project :accessor ql-release-project)
   (url :type string :initarg :url :accessor ql-release-url)
   (size :type integer :initarg :size :accessor ql-release-size)
   (file-md5 :type string :initarg :file-md5 :accessor ql-release-file-md5)
   (content-sha1 :type string :initarg :content-sha1 :accessor ql-release-content-sha1)
   (prefix :type string :initarg :prefix :accessor ql-release-prefix)
   (system-files :type list :initarg :system-files :accessor ql-release-system-files :initform nil)))

(defclass ql-system ()
  ((project :type string :initarg :project :accessor ql-system-project)
   (system-file :type string :initarg :system-file :accessor ql-system-system-file)
   (system-name :type string :initarg :system-name :accessor ql-system-system-name)
   (dependencies :type list :initarg :dependencies :accessor ql-system-dependencies :initform nil)))

(defun parse-distinfo (text)
  "Parse distinfo.txt content (string). Returns a QL-DIST object."
  (let ((kv (make-hash-table :test 'equal)))
    (dolist (line (uiop:split-string text :separator '(#\Newline)))
      (let ((pos (position #\: line)))
        (when pos
          (setf (gethash (string-trim " " (subseq line 0 pos)) kv)
                (string-trim " " (subseq line (1+ pos)))))))
    (make-instance 'ql-dist
                   :name (gethash "name" kv "quicklisp")
                   :version (gethash "version" kv "")
                   :system-index-url (gethash "system-index-url" kv "")
                   :release-index-url (gethash "release-index-url" kv "")
                   :archive-base-url (gethash "archive-base-url" kv ""))))

(defun parse-releases (text)
  "Parse releases.txt content. Returns a list of QL-RELEASE objects."
  (let ((releases nil))
    (dolist (line (uiop:split-string text :separator '(#\Newline)))
      (unless (or (zerop (length line)) (char= (char line 0) #\#))
        (let ((parts (uiop:split-string line :separator '(#\Space))))
          (when (>= (length parts) 6)
            (push (make-instance 'ql-release
                                 :project (nth 0 parts)
                                 :url (nth 1 parts)
                                 :size (parse-integer (nth 2 parts) :junk-allowed t)
                                 :file-md5 (nth 3 parts)
                                 :content-sha1 (nth 4 parts)
                                 :prefix (nth 5 parts)
                                 :system-files (nthcdr 6 parts))
                  releases)))))
    (nreverse releases)))

(defun parse-systems (text)
  "Parse systems.txt content. Returns a list of QL-SYSTEM objects."
  (let ((systems nil))
    (dolist (line (uiop:split-string text :separator '(#\Newline)))
      (unless (or (zerop (length line)) (char= (char line 0) #\#))
        (let ((parts (uiop:split-string line :separator '(#\Space))))
          (when (>= (length parts) 3)
            (push (make-instance 'ql-system
                                 :project (nth 0 parts)
                                 :system-file (nth 1 parts)
                                 :system-name (nth 2 parts)
                                 :dependencies (nthcdr 3 parts))
                  systems)))))
    (nreverse systems)))

(defun fetch-text (url)
  "Fetch a URL and return its content as a string."
  (let ((body (dex:get url)))
    (etypecase body
      (string body)
      ((vector (unsigned-byte 8)) (babel:octets-to-string body :encoding :utf-8)))))

(defun fetch-and-parse-dist (distinfo-url)
  "Fetch and parse a complete Quicklisp dist.
   Returns (values dist releases systems)."
  (let* ((dist-text (fetch-text distinfo-url))
         (dist (parse-distinfo dist-text))
         (releases-text (fetch-text (ql-dist-release-index-url dist)))
         (systems-text (fetch-text (ql-dist-system-index-url dist)))
         (releases (parse-releases releases-text))
         (systems (parse-systems systems-text)))
    (values dist releases systems)))
