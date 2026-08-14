(defpackage :cl-oci-client/registry
  (:use :cl)
  (:import-from :cl-oci-client/conditions #:registry-error #:auth-error)
  (:import-from :cl-oci-client/auth
                #:auth-config #:auth-config-token #:make-auth-config
                #:obtain-token #:make-auth-headers)
  (:import-from :cl-oci-client/http
                #:http-exchange #:response-header-value)
  (:export #:registry
           #:registry-url
           #:registry-auth
           #:registry-insecure-p
           #:make-registry
           #:ping
           #:registry-request
           #:parse-reference))
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
        (t (error 'registry-error :status status :url url :body body))))))

(defun registry-request (registry method path &key content content-type headers
                                                 accept (handle-auth t))
  "Make an authenticated HTTP request to the registry.
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
                       :decompress nil)
      (cond
        ((<= 200 status 299)
         (values body status resp-headers))
        ((and handle-auth (= status 401))
         (handle-auth-challenge registry resp-headers)
         (registry-request registry method path
                           :content content :content-type content-type
                           :headers headers :accept accept :handle-auth nil))
        (t (error 'registry-error
                  :status status
                  :url url
                  :body body))))))

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
