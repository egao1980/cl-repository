(defpackage :cl-repository-client/config-store
  (:use :cl)
  (:import-from :babel #:string-to-octets)
  (:import-from :yason)
  (:import-from :cl-oci/digest #:compute-digest #:format-digest)
  (:import-from :cl-repository-client/atomic-file #:with-atomic-output-file)
  (:export #:config-store-directory
           #:stored-entry
           #:store-entry
           #:stored-config
           #:store-config))
(in-package :cl-repository-client/config-store)

;;; Package metadata on disk, between runs. Tags can move (nothing stops a
;;; re-publish of a version), so an entry records the digest the tag had
;;; when it was read, and is used only after a HEAD of the tag answers that
;;; same digest. An entry keeps what resolution and install read for a tag:
;;; the tag's manifest or index, the index's manifest, the config. A hit
;;; costs one HEAD instead of three GETs, for resolution and install both.
;;; Tag listings are never stored, so new releases are seen.

(defun config-store-directory ()
  "Where entries are kept: CL_REPO_CONFIG_CACHE when it names a directory,
   NIL (no store) when it is 0, off or no, else
   <XDG_CACHE_HOME>/cl-repository/configs/."
  (let ((v (uiop:getenv "CL_REPO_CONFIG_CACHE")))
    (cond ((and v (member v '("0" "off" "no" "false") :test #'string-equal)) nil)
          ((and v (plusp (length v)))
           (uiop:ensure-directory-pathname (uiop:parse-native-namestring v)))
          (t (uiop:xdg-cache-home "cl-repository" "configs/")))))

(defun entry-file (directory registry-url repository tag)
  (let ((key (format-digest
              (compute-digest (string-to-octets
                               (format nil "~a~%~a~%~a" registry-url repository tag)
                               :encoding :utf-8)))))
    (merge-pathnames (format nil "~a.json" (subseq key (1+ (position #\: key))))
                     directory)))

(defparameter +entry-keys+
  '((:digest . "digest") (:config . "config") (:index . "index")
    (:index-type . "index-type") (:manifest-digest . "manifest-digest")
    (:manifest . "manifest")))

(defun stored-entry (registry-url repository tag)
  "The entry stored for TAG of REPOSITORY: a plist with :DIGEST (of the
   tag's manifest or index), :CONFIG (config JSON) and, when stored,
   :INDEX, :INDEX-TYPE, :MANIFEST-DIGEST, :MANIFEST. NIL when there is none."
  (let ((dir (config-store-directory)))
    (when dir
      (ignore-errors
       (let ((file (entry-file dir registry-url repository tag)))
         (when (probe-file file)
           (let ((table (yason:parse (uiop:read-file-string file :external-format :utf-8))))
             (when (and (hash-table-p table)
                        (stringp (gethash "digest" table))
                        (stringp (gethash "config" table)))
               (loop for (key . name) in +entry-keys+
                     for value = (gethash name table)
                     when (stringp value) collect key and collect value)))))))))

(defun store-entry (registry-url repository tag entry)
  "Store ENTRY (a plist as STORED-ENTRY returns) for TAG of REPOSITORY. A
   failure to write is not an error: the store is only a cache."
  (let ((dir (config-store-directory)))
    (when (and dir (getf entry :digest) (getf entry :config))
      (ignore-errors
       (ensure-directories-exist dir)
       (let ((table (make-hash-table :test 'equal)))
         (loop for (key . name) in +entry-keys+
               for value = (getf entry key)
               when value do (setf (gethash name table) value))
         (let ((octets (string-to-octets (with-output-to-string (s) (yason:encode table s))
                                         :encoding :utf-8)))
           (with-atomic-output-file (out (entry-file dir registry-url repository tag)
                                         :element-type '(unsigned-byte 8))
             (write-sequence octets out))))
       t))))

(defun stored-config (registry-url repository tag)
  "(values digest config-json) stored for TAG of REPOSITORY, or NIL."
  (let ((entry (stored-entry registry-url repository tag)))
    (when entry
      (values (getf entry :digest) (getf entry :config)))))

(defun store-config (registry-url repository tag digest config-json)
  "Store just the config of TAG at DIGEST."
  (store-entry registry-url repository tag (list :digest digest :config config-json)))
