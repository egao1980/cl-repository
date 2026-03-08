(defpackage :cl-oci-client/auth
  (:use :cl)
  (:import-from :dexador)
  (:import-from :yason)
  (:import-from :cl-ppcre)
  (:import-from :cl-base64)
  (:import-from :cl-oci-client/conditions #:auth-error)
  (:export #:auth-config
           #:auth-config-username
           #:auth-config-password
           #:auth-config-token
           #:make-auth-config
           #:obtain-token
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

(defun obtain-token (www-authenticate-header &optional auth &key insecure)
  "Request a bearer token from the auth endpoint described in WWW-Authenticate header."
  (let* ((params (parse-www-authenticate www-authenticate-header))
         (realm (gethash "realm" params))
         (service (gethash "service" params))
         (scope (gethash "scope" params)))
    (unless realm
      (error 'auth-error :status 401 :body "No realm in WWW-Authenticate header"))
    (let* ((url (format nil "~a?service=~a~@[&scope=~a~]"
                        realm (or service "") scope))
           (headers (when (and auth (auth-config-username auth))
                      (list (cons "Authorization"
                                  (format nil "Basic ~a"
                                          (cl-base64:string-to-base64-string
                                           (format nil "~a:~a"
                                                   (auth-config-username auth)
                                                   (or (auth-config-password auth) ""))))))))
           (response (handler-case
                         (dex:get url :headers headers :insecure insecure)
                       (dex:http-request-failed (e)
                         (error 'auth-error
                                :status (dex:response-status e)
                                :url url
                                :body (dex:response-body e)))))
           (json (yason:parse response)))
      (or (gethash "token" json)
          (gethash "access_token" json)
          (error 'auth-error :status 401 :body "No token in auth response")))))

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
