(defpackage :cl-oci-client/auth
  (:use :cl)
  (:import-from :yason)
  (:import-from :cl-ppcre)
  (:import-from :cl-base64)
  (:import-from :babel #:octets-to-string)
  (:import-from :quri #:url-encode)
  (:import-from :cl-oci-client/conditions #:auth-error #:error-body-text)
  (:import-from :cl-oci-client/http #:http-exchange)
  (:export #:auth-config
           #:auth-config-username
           #:auth-config-password
           #:auth-config-token
           #:make-auth-config
           #:obtain-token
           #:token-request
           #:parse-token-response
           #:parse-www-authenticate
           #:make-auth-headers))
(in-package :cl-oci-client/auth)

(defclass auth-config ()
  ((username :type (or null string) :initarg :username :accessor auth-config-username :initform nil)
   (password :type (or null string) :initarg :password :accessor auth-config-password :initform nil)
   (token :type (or null string) :initarg :token :accessor auth-config-token :initform nil)))

(defun make-auth-config (&key username password token)
  (make-instance 'auth-config :username username :password password :token token))

(defun parse-www-authenticate (header)
  "Parse a WWW-Authenticate: Bearer realm=\"...\",service=\"...\",scope=\"...\" header."
  (let ((params (make-hash-table :test 'equal)))
    (cl-ppcre:do-register-groups (key value)
        ("(\\w+)=\"([^\"]+)\"" header)
      (setf (gethash key params) value))
    params))

(defun token-request (www-authenticate-header &key auth)
  "The token request a WWW-Authenticate challenge asks for: (values url headers)."
  (let* ((params (parse-www-authenticate www-authenticate-header))
         (realm (gethash "realm" params))
         (service (gethash "service" params))
         (scope (gethash "scope" params)))
    (unless realm
      (error 'auth-error :status 401 :body "No realm in WWW-Authenticate header"))
    (values (format nil "~a?service=~a~@[&scope=~a~]"
                    realm
                    (url-encode (or service ""))
                    (when scope (url-encode scope)))
            (when (and auth (auth-config-username auth))
              (list (cons "Authorization"
                          (format nil "Basic ~a"
                                  (cl-base64:string-to-base64-string
                                   (format nil "~a:~a"
                                           (auth-config-username auth)
                                           (or (auth-config-password auth) ""))))))))))

(defun parse-token-response (body status url)
  "The token in a token endpoint's answer: (values token expires-in-seconds-or-nil)."
  (unless (<= 200 status 299)
    (error 'auth-error :status status :url url :body (error-body-text body)))
  (let* ((text (etypecase body
                 (string body)
                 ((vector (unsigned-byte 8))
                  (octets-to-string body :encoding :utf-8))))
         (json (yason:parse text)))
    (values (or (gethash "token" json)
                (gethash "access_token" json)
                (error 'auth-error :status 401 :body "No token in auth response"))
            ;; seconds the token is valid (RFC 6750 expires_in), or NIL
            (let ((s (gethash "expires_in" json)))
              (and (integerp s) (plusp s) s)))))

(defun obtain-token (www-authenticate-header &key auth insecure)
  "Request a bearer token from the auth endpoint described in WWW-Authenticate header.
   Returns (values token expires-in-seconds-or-nil)."
  (multiple-value-bind (url headers) (token-request www-authenticate-header :auth auth)
    (multiple-value-bind (body status)
        (http-exchange :get url :headers headers :force-binary nil :verify (not insecure))
      (parse-token-response body status url))))

(defun make-auth-headers (auth)
  "Build HTTP headers for authentication."
  (when auth
    (cond
      ((auth-config-token auth)
       (list (cons "Authorization" (format nil "Bearer ~a" (auth-config-token auth)))))
      ((auth-config-username auth)
       (list (cons "Authorization"
                   (format nil "Basic ~a"
                           (cl-base64:string-to-base64-string
                            (format nil "~a:~a"
                                    (auth-config-username auth)
                                    (or (auth-config-password auth) "")))))))
      (t nil))))
