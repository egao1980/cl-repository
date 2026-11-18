(defpackage :cl-oci-client/registry
  (:use :cl)
  (:import-from :cl-oci-client/conditions #:registry-error #:auth-error #:not-found-error)
  (:import-from :babel #:octets-to-string)
  (:import-from :cl-oci-client/auth
                #:auth-config #:auth-config-token #:make-auth-config
                #:obtain-token #:make-auth-headers)
  (:import-from :cl-oci-client/http
                #:http-exchange #:response-header-value)
  (:export #:registry
           #:signal-registry-error
           #:registry-url
           #:registry-auth
           #:registry-insecure-p
           #:make-registry
           #:ping
           #:registry-request
           #:parse-reference
           #:blob-timeout))
(in-package :cl-oci-client/registry)

(defclass registry ()
  ((url :type string :initarg :url :accessor registry-url)
   (auth :type (or null auth-config) :initarg :auth :accessor registry-auth :initform nil)
   (insecure-p :type boolean :initarg :insecure-p :accessor registry-insecure-p :initform nil)))

(defun make-registry (url &key auth insecure-p)
  (make-instance 'registry
                 :url (string-right-trim "/" url)
                 :auth auth
                 :insecure-p insecure-p))

(defun base-url (registry)
  (let ((url (registry-url registry)))
    (if (or (search "://" url) (registry-insecure-p registry))
        url
        (format nil "https://~a" url))))

(defun api-url (registry path)
  "Construct full API URL. If PATH is already absolute (contains ://), use as-is."
  (if (search "://" path)
      path
      (format nil "~a~a" (base-url registry) path)))

(defun %verify (registry)
  (not (registry-insecure-p registry)))

(defun handle-auth-challenge (registry headers)
  "Handle 401 by extracting WWW-Authenticate and obtaining a token."
  (let ((www-auth (response-header-value headers "www-authenticate")))
    (when www-auth
      (let ((token (obtain-token www-auth
                                 :auth (registry-auth registry)
                                 :insecure (registry-insecure-p registry))))
        (if (registry-auth registry)
            (setf (auth-config-token (registry-auth registry)) token)
            (setf (registry-auth registry) (make-auth-config :token token)))
        t))))

(defun error-body-text (body)
  "BODY of a failed registry response as text. Registries answer errors with a
   JSON document; a request that forces binary hands back octets."
  (if (typep body '(vector (unsigned-byte 8)))
      (octets-to-string body :encoding :utf-8 :errorp nil)
      body))

(defun signal-registry-error (status url body)
  "Signal the REGISTRY-ERROR subtype for HTTP STATUS: AUTH-ERROR for 401/403,
   NOT-FOUND-ERROR for 404, REGISTRY-ERROR otherwise."
  (error (case status
           ((401 403) 'auth-error)
           (404 'not-found-error)
           (t 'registry-error))
         :status status :url url :body (error-body-text body)))

(defun ping (registry)
  "Check if the registry supports OCI Distribution Spec (GET /v2/)."
  (let ((url (api-url registry "/v2/")))
    (multiple-value-bind (body status headers)
        (http-exchange :get url
                       :headers (make-auth-headers (registry-auth registry))
                       :force-binary nil
                       :verify (%verify registry))
      (declare (ignore body))
      (cond
        ((<= 200 status 299) t)
        ((= status 401)
         (handle-auth-challenge registry headers))
        (t (signal-registry-error status url body))))))

(defvar *blob-timeout* 3600
  "Seconds a blob GET or PUT may take, body included; CL_REPO_BLOB_TIMEOUT
   overrides it. http-backend-async times the whole exchange, so its 30 s default
   fails a CUDA overlay layer (about 1 GB) even on a fast link.")

(defun blob-timeout ()
  "*BLOB-TIMEOUT*, or CL_REPO_BLOB_TIMEOUT when that is a positive integer."
  (let* ((v (uiop:getenv "CL_REPO_BLOB_TIMEOUT"))
         (n (and v (plusp (length v)) (parse-integer v :junk-allowed t))))
    (if (and n (plusp n)) n *blob-timeout*)))

(defun registry-request (registry method path &key content content-type headers
                                  accept (handle-auth t) timeout)
  "Make an authenticated HTTP request to the registry.
   TIMEOUT overrides the HTTP client's default (see BLOB-TIMEOUT).
   Returns (values body status response-headers)."
  (let* ((url (api-url registry path))
         (auth-hdrs (make-auth-headers (registry-auth registry)))
         (all-headers (append auth-hdrs
                              (when content-type
                                (list (cons "Content-Type" content-type)))
                              (when accept
                                (list (cons "Accept" accept)))
                              headers)))
    (multiple-value-bind (body status resp-headers)
        (http-exchange method url
                       :headers all-headers
                       :content content
                       :force-binary t
                       :verify (%verify registry)
                       ;; Blobs/manifests are opaque octets — don't CE-decode.
                       :decompress nil
                       :timeout timeout)
      (cond
       ((<= 200 status 299)
        (values body status resp-headers))
       ((and handle-auth (= status 401))
        (handle-auth-challenge registry resp-headers)
        (registry-request registry method path
                          :content content :content-type content-type
                          :headers headers :accept accept :handle-auth nil
                          :timeout timeout))
       (t (signal-registry-error status url body))))))

(defun parse-reference (reference)
  "Parse a reference like 'ghcr.io/namespace/name:tag' or 'registry/name@sha256:...'
   Returns (values registry-host repository tag-or-digest)."
  (let* ((at-pos (position #\@ reference))
         (colon-pos (and (not at-pos) (position #\: reference :from-end t))))
    (multiple-value-bind (repo-part ref-part)
        (cond
          (at-pos (values (subseq reference 0 at-pos) (subseq reference (1+ at-pos))))
          (colon-pos (values (subseq reference 0 colon-pos) (subseq reference (1+ colon-pos))))
          (t (values reference "latest")))
      (let ((slash-pos (position #\/ repo-part)))
        (if (and slash-pos
                 (or (search "." (subseq repo-part 0 slash-pos))
                     (search ":" (subseq repo-part 0 slash-pos))
                     (string= "localhost" (subseq repo-part 0 slash-pos))))
            (values (subseq repo-part 0 slash-pos)
                    (subseq repo-part (1+ slash-pos))
                    ref-part)
            (values nil repo-part ref-part))))))
