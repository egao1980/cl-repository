(defpackage :cl-oci-client/auth
  (:use :cl)
  (:import-from :yason)
  (:import-from :cl-ppcre)
  (:import-from :cl-base64)
  (:import-from :babel #:octets-to-string)
  (:import-from :quri #:url-encode)
  (:import-from :cl-oci-client/conditions #:auth-error #:credentials-rejected #:error-body-text)
  (:import-from :cl-oci-client/http #:http-exchange)
  (:export #:auth-config
           #:auth-config-username
           #:auth-config-password
           #:auth-config-token
           #:auth-config-source
           #:make-auth-config
           #:credentials-p
           #:redact-secret
           #:obtain-token
           #:token-request
           #:parse-token-response
           #:parse-www-authenticate
           #:make-auth-headers))
(in-package :cl-oci-client/auth)

(defclass auth-config ()
  ((username :type (or null string) :initarg :username :accessor auth-config-username :initform nil)
   (password :type (or null string) :initarg :password :accessor auth-config-password :initform nil)
   (token :type (or null string) :initarg :token :accessor auth-config-token :initform nil)
   ;; where USERNAME/PASSWORD came from, for messages: "GITHUB_TOKEN", a
   ;; file name. Never the secret itself.
   (source :type (or null string) :initarg :source :accessor auth-config-source :initform nil)))

(defun make-auth-config (&key username password token source)
  (make-instance 'auth-config :username username :password password :token token
                              :source source))

(defmethod print-object ((auth auth-config) stream)
  "Printed with the secrets redacted: an AUTH-CONFIG ends up in backtraces
   and debug output."
  (print-unreadable-object (auth stream :type t :identity t)
    (format stream "~@[user ~a~]~@[ from ~a~]~:[~; password <redacted>~]~:[~; token <redacted>~]"
            (auth-config-username auth)
            (auth-config-source auth)
            (auth-config-password auth)
            (auth-config-token auth))))

(defun credentials-p (auth)
  "True when AUTH has credentials (a username, sent as Basic auth), not only
   a bearer token."
  (and auth (auth-config-username auth) t))

(defun redact-secret (text secret)
  "TEXT with every occurrence of SECRET replaced by <redacted>. TEXT that is
   not a string, and a SECRET that is NIL or empty, come back unchanged."
  (if (and (stringp text) (stringp secret) (plusp (length secret)))
      (cl-ppcre:regex-replace-all (cl-ppcre:quote-meta-chars secret) text "<redacted>")
      text))

(defun parse-www-authenticate (header)
  "Parse a WWW-Authenticate: Bearer realm=\"...\",service=\"...\",scope=\"...\" header."
  (let ((params (make-hash-table :test 'equal)))
    (cl-ppcre:do-register-groups (key value)
        ("(\\w+)=\"([^\"]+)\"" header)
      (setf (gethash key params) value))
    params))

(defun token-request (www-authenticate-header &key auth without-scope)
  "The token request a WWW-Authenticate challenge asks for: (values url headers).
   AUTH with credentials adds their Basic Authorization header. WITHOUT-SCOPE
   leaves the challenge's scope out, as `docker login` does to check
   credentials."
  (let* ((params (parse-www-authenticate www-authenticate-header))
         (realm (gethash "realm" params))
         (service (gethash "service" params))
         (scope (and (not without-scope) (gethash "scope" params))))
    (unless realm
      (error 'auth-error :status 401 :body "No realm in WWW-Authenticate header"))
    (values (format nil "~a?service=~a~@[&scope=~a~]"
                    realm
                    (url-encode (or service ""))
                    (when scope (url-encode scope)))
            (when (credentials-p auth)
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

(defun %token-exchange (www-authenticate-header auth insecure &key without-scope)
  "GET the token TOKEN-REQUEST describes: (values body status url)."
  (multiple-value-bind (url headers)
      (token-request www-authenticate-header :auth auth :without-scope without-scope)
    (multiple-value-bind (body status)
        (http-exchange :get url :headers headers :force-binary nil :verify (not insecure))
      (values body status url))))

(defun credentials-refused-p (www-authenticate-header auth &key insecure)
  "True when the token endpoint of WWW-AUTHENTICATE-HEADER refuses AUTH's
   credentials outright: 401/403 for a token without a scope, which is what
   `docker login` asks for. Credentials that get one are good, so a refusal
   for one repository's scope is about that repository (it does not exist,
   or is not shared with them)."
  (member (nth-value 1 (%token-exchange www-authenticate-header auth insecure
                                        :without-scope t))
          '(401 403)))

(defun obtain-token (www-authenticate-header &key auth insecure)
  "Request a bearer token from the auth endpoint described in WWW-Authenticate header.
   Returns (values token expires-in-seconds-or-nil).
   AUTH's credentials are sent as Basic auth. When the endpoint refuses them
   outright (CREDENTIALS-REFUSED-P) this signals CREDENTIALS-REJECTED; a
   refusal for the scope alone is the AUTH-ERROR an anonymous one gives.
   Error bodies never carry the password."
  (multiple-value-bind (body status url) (%token-exchange www-authenticate-header auth insecure)
    (let ((refused (and (member status '(401 403)) (credentials-p auth))))
      (when refused
        (setf body (redact-secret (error-body-text body) (auth-config-password auth))))
      (when (and refused (credentials-refused-p www-authenticate-header auth :insecure insecure))
        (error 'credentials-rejected :status status :url url :body body
                                     :source (auth-config-source auth)
                                     :username (auth-config-username auth)))
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
