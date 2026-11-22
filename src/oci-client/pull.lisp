(defpackage :cl-oci-client/pull
  (:use :cl)
  (:import-from :babel #:octets-to-string)
  (:import-from :cl-oci-client/registry #:registry #:registry-request #:registry-url)
  (:import-from :cl-oci-client/conditions #:not-found-error #:registry-error)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+ #:+oci-image-index-v1+
                #:+docker-manifest-v2+ #:+docker-manifest-list-v2+)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :yason)
  (:export #:pull-manifest
           #:pull-manifest-raw
           #:parse-manifest-body
           #:*default-accept*
           #:pull-blob
           #:head-manifest
           #:head-blob
           #:manifest-exists-p
           #:blob-exists-p
           #:*pull-cache*
           #:remember-pull))
(in-package :cl-oci-client/pull)

(defparameter *default-accept*
  (format nil "~a, ~a, ~a, ~a"
          +oci-image-manifest-v1+ +oci-image-index-v1+
          +docker-manifest-v2+ +docker-manifest-list-v2+))

;;; Pulls within one operation
;;;
;;; Resolution reads each package's manifest and config blob; installing
;;; the package read them again. Bound to a table for an operation (a sync,
;;; an install), *PULL-CACHE* keeps manifests and small blobs for its length.

(defvar *pull-cache* nil
  "NIL, or an EQUAL hash table (registry-url repository reference) →
   (body status headers) of the manifests and small blobs pulled in the
   current operation.")

(defparameter *pull-cache-max-blob* (* 1024 1024)
  "Largest blob *PULL-CACHE* keeps, in octets: configs, not layers.")

(defun remember-pull (registry repository reference answer)
  "Keep ANSWER, (body status headers) of a pull of REFERENCE, for the rest
   of the operation."
  (when (and *pull-cache* (consp answer))
    (setf (gethash (list (registry-url registry) repository reference) *pull-cache*)
          answer)))

(defun %cached-pull (registry repository reference thunk &optional max-size)
  (let ((key (and *pull-cache* (list (registry-url registry) repository reference))))
    (let ((hit (and key (gethash key *pull-cache*))))
      (if hit
          (values-list hit)
          (let ((answer (multiple-value-list (funcall thunk))))
            (when (and key (or (null max-size) (<= (length (first answer)) max-size)))
              (setf (gethash key *pull-cache*) answer))
            (values-list answer))))))

(defun pull-manifest-raw (registry repository reference)
  "Pull a manifest as raw bytes. Returns (values body status headers)."
  (%cached-pull registry repository reference
                (lambda ()
                  (registry-request registry :get
                                    (format nil "/v2/~a/manifests/~a" repository reference)
                                    :accept *default-accept*))))

(defun pull-manifest (registry repository reference)
  "Pull and parse a manifest or image index. Returns the parsed OCI object."
  (multiple-value-bind (body status headers)
      (pull-manifest-raw registry repository reference)
    (declare (ignore status))
    (parse-manifest-body body headers)))

(defun parse-manifest-body (body headers)
  "Parse a manifest or image index BODY (octets or text) as PULL-MANIFEST-RAW
   returned it with its response HEADERS. Returns the parsed OCI object."
  (let* ((content-type (gethash "content-type" headers))
         (json-str (etypecase body
                     (string body)
                     ((vector (unsigned-byte 8))
                      (babel:octets-to-string body :encoding :utf-8))))
         (json (yason:parse json-str)))
    (cond
      ((or (search "image.index" (or content-type ""))
           (search "manifest.list" (or content-type ""))
           (equalp (gethash "mediaType" json) +oci-image-index-v1+))
       (from-json 'image-index json))
      (t
       (from-json 'manifest json)))))

(defun pull-blob (registry repository digest)
  "Pull a blob by digest. Returns the blob as octets.
   A layer can be gigabytes, so the GET gets BLOB-TIMEOUT, not the 30 s default."
  (%cached-pull registry repository digest
                (lambda ()
                  (registry-request registry :get
                                    (format nil "/v2/~a/blobs/~a" repository digest)
                                    :timeout (cl-oci-client/registry:blob-timeout)))
                *pull-cache-max-blob*))

(defun head-manifest (registry repository reference)
  "HEAD a manifest. Returns (values status headers) or signals NOT-FOUND-ERROR."
  (handler-case
      (multiple-value-bind (body status headers)
          (registry-request registry :head
                            (format nil "/v2/~a/manifests/~a" repository reference)
                            :accept *default-accept*)
        (declare (ignore body))
        (values status headers))
    (not-found-error () (values nil nil))))

(defun head-blob (registry repository digest)
  "HEAD a blob. Returns (values status headers) or NIL if not found."
  (handler-case
      (multiple-value-bind (body status headers)
          (registry-request registry :head
                            (format nil "/v2/~a/blobs/~a" repository digest))
        (declare (ignore body))
        (values status headers))
    (not-found-error () (values nil nil))))

(defun manifest-exists-p (registry repository reference)
  "Check if a manifest exists. Returns T or NIL."
  (multiple-value-bind (status headers) (head-manifest registry repository reference)
    (declare (ignore headers))
    (and status (= status 200))))

(defun blob-exists-p (registry repository digest)
  "Check if a blob exists. Returns T or NIL."
  (multiple-value-bind (status headers) (head-blob registry repository digest)
    (declare (ignore headers))
    (and status (= status 200))))
