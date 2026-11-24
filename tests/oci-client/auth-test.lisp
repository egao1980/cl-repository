(defpackage :cl-oci-client/tests/auth-test
  (:use :cl :rove)
  (:import-from :cl-oci-client/http #:*transport-retry*)
  (:import-from :cl-oci-client/auth
                #:make-auth-config #:token-request #:obtain-token #:redact-secret
                #:credentials-p)
  (:import-from :cl-oci-client/registry
                #:make-registry #:registry-request #:clear-token-cache)
  (:import-from :cl-oci-client/conditions
                #:auth-error #:credentials-rejected
                #:credentials-rejected-source #:credentials-rejected-username))
(in-package :cl-oci-client/tests/auth-test)

;;; Credentials against a scripted token endpoint (#186): Basic auth on the
;;; token request, refused credentials as CREDENTIALS-REJECTED, a refusal for
;;; one scope as the AUTH-ERROR an anonymous pull gets, and no secret in any
;;; printed form.

(defparameter *secret* "s3cret-Value")

(defclass scripted-backend (http-protocol:http-backend)
  ((handler :initarg :handler :reader scripted-handler)
   (requests :initform '() :accessor scripted-requests))
  (:default-initargs :name "scripted"))

(defmethod http-protocol:send ((backend scripted-backend) client request &key)
  (declare (ignore client))
  (push (list (http-protocol:http-request-method request)
              (http-protocol:http-request-url request)
              (cdr (assoc "Authorization" (http-protocol:http-request-headers request)
                          :test #'string-equal)))
        (scripted-requests backend))
  (funcall (scripted-handler backend) request))

(defun respond (status body &optional headers)
  (let ((table (make-hash-table :test #'equal)))
    (setf (gethash "content-type" table) "application/json")
    (loop for (k . v) in headers do (setf (gethash k table) v))
    (make-instance 'http-protocol:http-response
                   :status status :headers table
                   :body (babel:string-to-octets body :encoding :utf-8))))

(defun basic (user password)
  (format nil "Basic ~a" (cl-base64:string-to-base64-string
                          (format nil "~a:~a" user password))))

(defun challenge (repo)
  (format nil "Bearer realm=\"https://r.test/token\",service=\"r.test\",scope=\"repository:~a:pull\""
          repo))

(defun private-registry (request)
  "A ghcr-like registry with credentials u:good. ns/private needs them;
   ns/forbidden is refused even to them; everything else is public. A wrong
   password is refused at the token endpoint, with and without a scope, and
   the refusal echoes the password (to check that it is redacted)."
  (let* ((url (http-protocol:http-request-url request))
         (auth (cdr (assoc "Authorization" (http-protocol:http-request-headers request)
                           :test #'string-equal)))
         (good (equal auth (basic "u" "good"))))
    (cond
      ((search "/token" url)
       (cond
         ((and auth (not good))
          (respond 403 (format nil "{\"errors\":[{\"code\":\"DENIED\",\"message\":\"denied ~a\"}]}"
                               (subseq (cl-base64:base64-string-to-string (subseq auth 6))
                                       2))))
         ((search "ns%2Fforbidden" url)
          (respond 403 "{\"errors\":[{\"code\":\"DENIED\",\"message\":\"requested access to the resource is denied\"}]}"))
         ((and (search "ns%2Fprivate" url) (not good))
          (respond 401 "{\"errors\":[{\"code\":\"UNAUTHORIZED\",\"message\":\"authentication required\"}]}"))
         (t (respond 200 "{\"token\": \"bearer-ok\"}"))))
      ((equal auth "Bearer bearer-ok") (respond 200 "{\"tags\": [\"1.0\"]}"))
      (t (let ((repo (subseq url (+ 4 (search "/v2/" url)) (search "/tags/" url))))
           (respond 401 "{}" `(("www-authenticate" . ,(challenge repo)))))))))

(defun call-with-scripted-backend (handler fn)
  (let* ((backend (make-instance 'scripted-backend :handler handler))
         (http-protocol:*http-backend* backend)
         (cl-oci-client/http::*http-clients* '())
         (*transport-retry* nil))
    (clear-token-cache)
    (unwind-protect (funcall fn backend)
      (clear-token-cache))))

(defun token-requests (backend)
  (remove-if-not (lambda (r) (search "/token" (second r))) (scripted-requests backend)))

(defun credentials (password)
  (make-auth-config :username "u" :password password :source "CL_REPO_REGISTRY_TOKEN"))

(deftest token-request-sends-credentials-as-basic
  (multiple-value-bind (url headers)
      (token-request (challenge "ns/a") :auth (credentials "pw"))
    (ok (search "scope=repository%3Ans%2Fa%3Apull" url))
    (ok (equal (basic "u" "pw") (cdr (assoc "Authorization" headers :test #'string=)))))
  (multiple-value-bind (url headers) (token-request (challenge "ns/a"))
    (ok (search "scope=" url))
    (ok (null headers) "anonymous: no Authorization header"))
  (multiple-value-bind (url headers)
      (token-request (challenge "ns/a") :auth (make-auth-config :token "t"))
    (declare (ignore url))
    (ok (null headers) "a bearer token alone is not sent to the token endpoint"))
  (let ((url (token-request (challenge "ns/a") :auth (credentials "pw") :without-scope t)))
    (ok (null (search "scope=" url)) "WITHOUT-SCOPE: no scope, as docker login asks"))
  (ok (credentials-p (credentials "pw")))
  (ng (credentials-p (make-auth-config :token "t")))
  (ng (credentials-p nil)))

(deftest good-credentials-pull-a-private-repository
  (call-with-scripted-backend
   #'private-registry
   (lambda (backend)
     (let ((reg (make-registry "https://r.test" :auth (credentials "good"))))
       (ok (= 200 (nth-value 1 (registry-request reg :get "/v2/ns/private/tags/list"))))
       (ok (= 1 (length (token-requests backend))))
       (ok (every (lambda (r) (equal (basic "u" "good") (third r))) (token-requests backend))
           "the token request carried the credentials")
       (ok (notany (lambda (r) (and (third r) (eql 0 (search "Basic" (third r)))))
                   (set-difference (scripted-requests backend) (token-requests backend)))
           "the registry itself never got them: only the token endpoint")))))

(deftest refused-credentials-signal-credentials-rejected
  (call-with-scripted-backend
   #'private-registry
   (lambda (backend)
     (let* ((reg (make-registry "https://r.test" :auth (credentials *secret*)))
            (e (handler-case (progn (registry-request reg :get "/v2/ns/private/tags/list") nil)
                 (credentials-rejected (c) c)))
            (report (and e (princ-to-string e))))
       (ok (typep e 'credentials-rejected))
       (ok (typep e 'auth-error) "still an authentication failure")
       (ok (equal "CL_REPO_REGISTRY_TOKEN" (credentials-rejected-source e)))
       (ok (equal "u" (credentials-rejected-username e)))
       (ok (search "CL_REPO_REGISTRY_TOKEN" report) "the report names the variable")
       (ng (search *secret* report) "never its value")
       (ok (search "<redacted>" report) "an echoed secret is redacted")
       (ok (find-if (lambda (r) (null (search "scope=" (second r)))) (token-requests backend))
           "the credentials were checked without a scope")))))

(deftest credentials-refused-for-one-scope-are-an-auth-error
  "Good credentials refused for one repository: the repository is absent or
   not shared, as an anonymous refusal says. Not CREDENTIALS-REJECTED."
  (call-with-scripted-backend
   #'private-registry
   (lambda (backend)
     (declare (ignore backend))
     (let* ((reg (make-registry "https://r.test" :auth (credentials "good")))
            (e (handler-case (progn (registry-request reg :get "/v2/ns/forbidden/tags/list") nil)
                 (auth-error (c) c))))
       (ok (typep e 'auth-error))
       (ng (typep e 'credentials-rejected))))))

(deftest an-anonymous-refusal-is-an-auth-error
  (call-with-scripted-backend
   #'private-registry
   (lambda (backend)
     (let* ((reg (make-registry "https://r.test"))
            (e (handler-case (progn (registry-request reg :get "/v2/ns/private/tags/list") nil)
                 (auth-error (c) c))))
       (ok (typep e 'auth-error))
       (ng (typep e 'credentials-rejected))
       (ok (= 1 (length (token-requests backend))) "no credential check without credentials")
       (ok (every (lambda (r) (null (third r))) (scripted-requests backend))
           "nothing carried an Authorization header")))))

(deftest a-public-repository-needs-no-credentials
  (call-with-scripted-backend
   #'private-registry
   (lambda (backend)
     (declare (ignore backend))
     (ok (= 200 (nth-value 1 (registry-request (make-registry "https://r.test")
                                               :get "/v2/ns/public/tags/list")))))))

(deftest obtain-token-redacts-a-refused-body
  (call-with-scripted-backend
   #'private-registry
   (lambda (backend)
     (declare (ignore backend))
     (let ((e (handler-case (obtain-token (challenge "ns/private") :auth (credentials *secret*))
                (credentials-rejected (c) c))))
       (ok (typep e 'credentials-rejected))
       (ng (search *secret* (princ-to-string e)))))))

(defun basic-registry (request)
  "A registry with Basic auth (registry:2 with htpasswd): u:good only."
  (if (equal (basic "u" "good")
             (cdr (assoc "Authorization" (http-protocol:http-request-headers request)
                         :test #'string-equal)))
      (respond 200 "{\"tags\": [\"1.0\"]}")
      (respond 401 "{}" '(("www-authenticate" . "Basic realm=\"Registry Realm\"")))))

(deftest a-basic-registry-gets-the-credentials-when-it-asks
  (call-with-scripted-backend
   #'basic-registry
   (lambda (backend)
     (ok (= 200 (nth-value 1 (registry-request (make-registry "https://r.test" :auth (credentials "good"))
                                               :get "/v2/ns/a/tags/list"))))
     (let ((sent (mapcar #'third (reverse (scripted-requests backend)))))
       (ok (equal (list nil (basic "u" "good")) sent)
           "first without them, then with them after the Basic challenge")
       (ok (null (token-requests backend)) "no token request to a Basic realm")))))

(deftest a-basic-challenge-refuses-credentials
  "A Basic registry answers wrong credentials with 401 again: there is no
   token to get, and the credentials were refused."
  (call-with-scripted-backend
   #'basic-registry
   (lambda (backend)
     (let ((e (handler-case
                  (progn (registry-request (make-registry "https://r.test" :auth (credentials *secret*))
                                           :get "/v2/ns/a/tags/list")
                    nil)
                (credentials-rejected (c) c))))
       (ok (typep e 'credentials-rejected))
       (ok (search "CL_REPO_REGISTRY_TOKEN" (princ-to-string e)))
       (ng (search *secret* (princ-to-string e))))
     (setf (scripted-requests backend) nil)
     (let ((e (handler-case
                  (progn (registry-request (make-registry "https://r.test") :get "/v2/ns/a/tags/list")
                    nil)
                (auth-error (c) c))))
       (ok (typep e 'auth-error) "anonymous: the 401 itself")
       (ng (typep e 'credentials-rejected))
       (ok (null (token-requests backend)) "no token request to a Basic realm")))))

(deftest auth-config-prints-redacted
  (let ((printed (prin1-to-string (credentials *secret*)))
        (token (prin1-to-string (make-auth-config :token *secret*))))
    (ng (search *secret* printed))
    (ok (search "CL_REPO_REGISTRY_TOKEN" printed))
    (ok (search "<redacted>" printed))
    (ng (search *secret* token)))
  (ok (equal "a <redacted> b" (redact-secret "a s3cret-Value b" *secret*)))
  (ok (equal "a.b" (redact-secret "a.b" "")) "an empty secret changes nothing")
  (ok (equal "x" (redact-secret "x" nil))))
