(defpackage :cl-oci-client/pull
  (:use :cl)
  (:import-from :babel #:octets-to-string)
  (:import-from :cl-oci-client/registry #:registry #:registry-request)
  (:import-from :cl-oci-client/conditions #:not-found-error #:registry-error)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+ #:+oci-image-index-v1+
                #:+docker-manifest-v2+ #:+docker-manifest-list-v2+)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :yason)
  (:export #:pull-manifest
           #:pull-manifest-raw
           #:pull-blob
           #:head-manifest
           #:head-blob
           #:manifest-exists-p
           #:blob-exists-p))
(in-package :cl-oci-client/pull)

(defparameter *default-accept*
  (format nil "~a, ~a, ~a, ~a"
          +oci-image-manifest-v1+ +oci-image-index-v1+
          +docker-manifest-v2+ +docker-manifest-list-v2+))

(defun pull-manifest-raw (registry repository reference)
  "Pull a manifest as raw bytes. Returns (values body status headers)."
  (registry-request registry :get
                    (format nil "/v2/~a/manifests/~a" repository reference)
                    :accept *default-accept*))

(defun pull-manifest (registry repository reference)
  "Pull and parse a manifest or image index. Returns the parsed OCI object."
  (multiple-value-bind (body status headers)
      (pull-manifest-raw registry repository reference)
    (declare (ignore status))
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
         (from-json 'manifest json))))))

(defun pull-blob (registry repository digest)
  "Pull a blob by digest. Returns the blob as octets."
  (registry-request registry :get
                    (format nil "/v2/~a/blobs/~a" repository digest)))

(defun head-manifest (registry repository reference)
  "HEAD a manifest. Returns (values status headers) or signals NOT-FOUND-ERROR."
  (handler-case
      (multiple-value-bind (body status headers)
          (registry-request registry :head
                            (format nil "/v2/~a/manifests/~a" repository reference)
                            :accept *default-accept*)
        (declare (ignore body))
        (values status headers))
    (registry-error (e)
      (if (eql (cl-oci-client/conditions:registry-error-status e) 404)
          (values nil nil)
          (error e)))))

(defun head-blob (registry repository digest)
  "HEAD a blob. Returns (values status headers) or NIL if not found."
  (handler-case
      (multiple-value-bind (body status headers)
          (registry-request registry :head
                            (format nil "/v2/~a/blobs/~a" repository digest))
        (declare (ignore body))
        (values status headers))
    (registry-error (e)
      (if (eql (cl-oci-client/conditions:registry-error-status e) 404)
          (values nil nil)
          (error e)))))

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
