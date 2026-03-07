(defpackage :cl-oci-client/push
  (:use :cl)
  (:import-from :babel #:string-to-octets)
  (:import-from :cl-oci-client/registry #:registry #:registry-request)
  (:import-from :cl-oci-client/conditions #:upload-error #:registry-error)
  (:import-from :cl-oci/digest #:format-digest)
  (:export #:push-blob-monolithic
           #:push-blob-check-and-push
           #:push-manifest
           #:mount-blob
           #:initiate-upload))
(in-package :cl-oci-client/push)

(defun initiate-upload (registry repository)
  "POST to initiate a blob upload. Returns the upload Location URL."
  (multiple-value-bind (body status headers)
      (registry-request registry :post
                        (format nil "/v2/~a/blobs/uploads/" repository)
                        :content (make-array 0 :element-type '(unsigned-byte 8)))
    (declare (ignore body status))
    (gethash "location" headers)))

(defun push-blob-monolithic (registry repository data digest)
  "Push a blob monolithically (POST then PUT).
   DATA is an octet vector, DIGEST is a formatted digest string like 'sha256:abc...'."
  (let ((location (initiate-upload registry repository)))
    (unless location
      (error 'upload-error :body "No upload location returned"))
    (let* ((sep (if (search "?" location) "&" "?"))
           (put-url (format nil "~a~adigest=~a" location sep digest)))
      (multiple-value-bind (body status headers)
          (registry-request registry :put put-url
                            :content data
                            :content-type "application/octet-stream")
        (declare (ignore body))
        (unless (= status 201)
          (error 'upload-error :status status :url put-url))
        (values (gethash "location" headers) status)))))

(defun push-blob-check-and-push (registry repository data digest)
  "Push blob only if it doesn't already exist (HEAD check first)."
  (handler-case
      (multiple-value-bind (body status headers)
          (registry-request registry :head
                            (format nil "/v2/~a/blobs/~a" repository digest))
        (declare (ignore body headers))
        (when (= status 200)
          (return-from push-blob-check-and-push (values nil :exists))))
    (registry-error () nil))
  (push-blob-monolithic registry repository data digest))

(defun push-manifest (registry repository reference manifest-json &key (content-type "application/vnd.oci.image.manifest.v1+json"))
  "Push a manifest (PUT). MANIFEST-JSON is the serialized JSON string or octets.
   REFERENCE is a tag or digest."
  (let ((content (etypecase manifest-json
                   (string (babel:string-to-octets manifest-json :encoding :utf-8))
                   ((vector (unsigned-byte 8)) manifest-json))))
    (multiple-value-bind (body status headers)
        (registry-request registry :put
                          (format nil "/v2/~a/manifests/~a" repository reference)
                          :content content
                          :content-type content-type)
      (declare (ignore body))
      (unless (= status 201)
        (error 'upload-error :status status))
      (values (gethash "location" headers)
              (gethash "docker-content-digest" headers)))))

(defun mount-blob (registry repository digest from-repository)
  "Mount a blob from another repository within the same registry."
  (handler-case
      (multiple-value-bind (body status headers)
          (registry-request registry :post
                            (format nil "/v2/~a/blobs/uploads/?mount=~a&from=~a"
                                    repository digest from-repository)
                            :content (make-array 0 :element-type '(unsigned-byte 8)))
        (declare (ignore body))
        (values (= status 201) (gethash "location" headers)))
    (registry-error () (values nil nil))))
