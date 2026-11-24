(defpackage :cl-oci-client/tests/batch-test
  (:use :cl :rove)
  (:import-from :cl-oci-client/http #:http-exchange)
  (:import-from :cl-oci-client/registry
                #:make-registry #:registry-request #:registry-request-batch #:clear-token-cache)
  (:import-from :cl-oci-client/conditions #:not-found-error #:registry-transport-error))
(in-package :cl-oci-client/tests/batch-test)

;;; REGISTRY-REQUEST-BATCH over a scripted registry. The batch transport is
;;; replaced by one that sends the requests one by one, without retries, as
;;; the event-loop batch does; the logic under test is what the registry
;;; layer makes of the answers.

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

(defun one-shot-batch (requests &key concurrency)
  (declare (ignore concurrency))
  (mapcar (lambda (r)
            (handler-case
                (multiple-value-list
                 (http-exchange (getf r :method) (getf r :url)
                                :headers (getf r :headers)
                                :force-binary (getf r :force-binary t)
                                :decompress (getf r :decompress t)
                                :retry nil))
              (error (e) e)))
          requests))

(defun call-with-batch-registry (handler fn)
  (let* ((backend (make-instance 'scripted-backend :handler handler))
         (sym 'cl-oci-client/http:http-exchange-batch)
         (orig (fdefinition sym))
         (old-jobs (uiop:getenv "CL_REPO_FETCH_JOBS")))
    (unwind-protect
        (let ((http-protocol:*http-backend* backend)
              (cl-oci-client/http::*http-backend-kind* :async)
              (cl-oci-client/http::*http-clients* '())
              (cl-oci-client/http:*host-outcomes* (make-hash-table :test 'equal))
              (cl-oci-client/http:*transport-retry*
               (make-instance 'cl-oci-client/http::transport-retry
                              :total 2 :backoff-factor 0 :status nil
                              :allowed-methods '(:get :head))))
          (setf (uiop:getenv "CL_REPO_FETCH_JOBS") "8")
          (setf (fdefinition sym) #'one-shot-batch)
          (clear-token-cache)
          (funcall fn backend))
      (setf (fdefinition sym) orig)
      (setf (uiop:getenv "CL_REPO_FETCH_JOBS") (or old-jobs ""))
      (clear-token-cache))))

(defun ghcr-like (request)
  "401 without a bearer token, a token per scope, 404 for repo missing,
   200 otherwise."
  (let ((url (http-protocol:http-request-url request))
        (auth (cdr (assoc "Authorization" (http-protocol:http-request-headers request)
                          :test #'string-equal))))
    (cond
      ((search "/token" url)
       (respond 200 (format nil "{\"token\": \"t-~a\"}"
                            (subseq url (1+ (position #\= url :from-end t))))))
      ((null auth)
       (let ((repo (subseq url (+ 4 (search "/v2/" url)) (search "/tags/" url))))
         (respond 401 "{}" `(("www-authenticate"
                              . ,(format nil "Bearer realm=\"https://r.test/token\",service=\"r.test\",scope=\"repository:~a:pull\""
                                         repo))))))
      ((search "/missing/" url) (respond 404 "{\"errors\": []}"))
      (t (respond 200 "{\"tags\": [\"1.0\"]}")))))

(deftest a-batch-answers-challenges-with-one-token-per-repository
  (call-with-batch-registry
   #'ghcr-like
   (lambda (backend)
     (let* ((reg (make-registry "https://r.test"))
            (results (registry-request-batch
                      (list (list reg :get "/v2/ns/a/tags/list")
                            (list (make-registry "https://r.test") :get "/v2/ns/b/tags/list")
                            (list (make-registry "https://r.test") :get "/v2/ns/a/tags/list")
                            (list (make-registry "https://r.test") :get "/v2/ns/missing/tags/list")))))
       (ok (= 200 (second (first results))))
       (ok (= 200 (second (second results))))
       (ok (= 200 (second (third results))))
       (ok (typep (fourth results) 'not-found-error) "a 404 is the error REGISTRY-REQUEST signals")
       (ok (= 3 (count-if (lambda (r) (search "/token" (second r))) (scripted-requests backend)))
           "one token per repository")
       ;; the token is kept: a later request to the repository sends it at once
       (setf (scripted-requests backend) nil)
       (registry-request (make-registry "https://r.test") :get "/v2/ns/a/tags/list")
       (ok (= 1 (length (scripted-requests backend))) "no challenge, no token request")
       (ok (search "t-" (third (first (scripted-requests backend)))))))))

(deftest a-batch-request-without-an-answer-is-sent-again-with-retries
  "A registry that has answered: a batch request that gets no response is
   sent again through REGISTRY-REQUEST, with its retries."
  (let ((failed nil))
    (call-with-batch-registry
     (lambda (request)
       (if (and (search "/ns/flaky/" (http-protocol:http-request-url request)) (not failed))
           (progn (setf failed t)
             (error 'http-protocol:http-protocol-error :message "incomplete HTTP response"))
           (ghcr-like request)))
     (lambda (backend)
       (declare (ignore backend))
       (registry-request (make-registry "https://r.test") :get "/v2/ns/ok/tags/list")
       (let ((results (registry-request-batch
                       (list (list (make-registry "https://r.test") :get "/v2/ns/flaky/tags/list")
                             (list (make-registry "https://r.test") :get "/v2/ns/ok/tags/list")))))
         (ok failed "the flaky request failed once")
         (ok (every (lambda (r) (and (consp r) (= 200 (second r)))) results)))))))

(deftest a-persistent-transport-failure-in-a-batch-is-a-transport-error
  "A registry that has answered: a batch request that keeps failing is a
   transport error, and the others keep their answers."
  (call-with-batch-registry
   (lambda (request)
     (if (search "/ns/down/" (http-protocol:http-request-url request))
         (error 'http-protocol:http-timeout-error :message "timed out")
         (ghcr-like request)))
   (lambda (backend)
     (declare (ignore backend))
     (registry-request (make-registry "https://r.test") :get "/v2/ns/ok/tags/list")
     (let ((results (registry-request-batch
                     (list (list (make-registry "https://r.test") :get "/v2/ns/down/tags/list")
                           (list (make-registry "https://r.test") :get "/v2/ns/ok/tags/list")))))
       (ok (typep (first results) 'registry-transport-error))
       (ok (= 200 (second (second results))))))))

(deftest a-batch-to-an-unreachable-registry-sends-one-request
  "#179: a batch of tag listings to a registry that refuses connections and
   has never answered. The first request fails, the others are not sent, and
   none is sent again with retries: every result is REGISTRY-UNREACHABLE."
  (call-with-batch-registry
   (lambda (request)
     (declare (ignore request))
     (error 'http-protocol:http-connection-error :message "connection refused"))
   (lambda (backend)
     (let ((results (registry-request-batch
                     (loop for name in '("a" "b" "c" "d" "e")
                           collect (list (make-registry "https://down.test") :get
                                         (format nil "/v2/ns/~a/tags/list" name))))))
       (ok (= 5 (length results)))
       (ok (every (lambda (r) (typep r 'cl-oci-client/conditions:registry-unreachable)) results)
           (format nil "~s" results))
       (ok (= 1 (length (scripted-requests backend)))
           (format nil "one request: ~s" (scripted-requests backend)))))))

(deftest path-repository-names-the-repository
  (ok (equal "ns/a" (cl-oci-client/registry::path-repository "/v2/ns/a/tags/list")))
  (ok (equal "egao1980/cl-systems/x"
             (cl-oci-client/registry::path-repository "/v2/egao1980/cl-systems/x/manifests/1.0")))
  (ok (equal "ns/a" (cl-oci-client/registry::path-repository "/v2/ns/a/blobs/sha256:00")))
  (ok (null (cl-oci-client/registry::path-repository "/v2/"))))

(deftest a-known-token-realm-saves-the-challenges
  "Once a registry's realm is known, a batch asks for the tokens of new
   repositories first: no 401 round trip each."
  (call-with-batch-registry
   #'ghcr-like
   (lambda (backend)
     (registry-request-batch (list (list (make-registry "https://r.test") :get "/v2/ns/a/tags/list")
                                   (list (make-registry "https://r.test") :get "/v2/ns/b/tags/list")))
     (setf (scripted-requests backend) nil)
     (let ((results (registry-request-batch
                     (list (list (make-registry "https://r.test") :get "/v2/ns/c/tags/list")
                           (list (make-registry "https://r.test") :get "/v2/ns/d/tags/list")))))
       (ok (every (lambda (r) (and (consp r) (= 200 (second r)))) results))
       (ok (= 4 (length (scripted-requests backend))) "two tokens, two requests")
       (ok (every #'third (remove-if (lambda (r) (search "/token" (second r)))
                                     (scripted-requests backend)))
           "every request carried its token")))))

(deftest a-known-token-realm-saves-the-challenges-with-credentials-too
  "A registry with credentials (#186) asks the known realm for its tokens
   first, sending the credentials there, instead of sending them to the
   registry and taking a 401 for each repository."
  (call-with-batch-registry
   #'ghcr-like
   (lambda (backend)
     (registry-request-batch (list (list (make-registry "https://r.test") :get "/v2/ns/a/tags/list")
                                   (list (make-registry "https://r.test") :get "/v2/ns/b/tags/list")))
     (setf (scripted-requests backend) nil)
     (flet ((credentialed ()
              (make-registry "https://r.test"
                             :auth (cl-oci-client/auth:make-auth-config
                                    :username "u" :password "pw" :source "TEST"))))
       (let ((results (registry-request-batch
                       (list (list (credentialed) :get "/v2/ns/c/tags/list")
                             (list (credentialed) :get "/v2/ns/d/tags/list"))))
             (tokens (remove-if-not (lambda (r) (search "/token" (second r)))
                                    (scripted-requests backend)))
             (others (remove-if (lambda (r) (search "/token" (second r)))
                                (scripted-requests backend))))
         (ok (every (lambda (r) (and (consp r) (= 200 (second r)))) results))
         (ok (= 2 (length tokens)) "one token per repository")
         (ok (every (lambda (r) (eql 0 (search "Basic " (third r)))) tokens)
             "the token requests carried the credentials")
         (ok (every (lambda (r) (eql 0 (search "Bearer t-" (third r)))) others)
             "the registry got bearer tokens, not the credentials"))))))
