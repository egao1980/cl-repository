(defpackage :cl-oci-client/tests/transport-test
  (:use :cl :rove)
  (:import-from :cl-oci-client/http #:http-exchange #:*transport-retry* #:transport-failure-p
                #:host-state #:url-host #:*unreachable-seconds* #:*connect-timeout*)
  (:import-from :cl-oci-client/auth #:obtain-token)
  (:import-from :cl-oci-client/registry #:make-registry #:registry-request)
  (:import-from :cl-oci-client/conditions
                #:auth-error #:registry-error-body #:error-body-summary
                #:registry-transport-error #:registry-transport-error-attempts
                #:registry-transport-error-cause
                #:registry-unreachable #:registry-unreachable-sent-p #:registry-unreachable-host))
(in-package :cl-oci-client/tests/transport-test)

;;; A fake transport: an http-protocol backend whose SEND runs a handler on
;;; each request. The handler returns an HTTP-RESPONSE (see RESPOND) or
;;; signals, as a real backend does on a network failure.

(defclass scripted-backend (http-protocol:http-backend)
  ((handler :initarg :handler :reader scripted-handler)
   (requests :initform '() :accessor scripted-requests))
  (:default-initargs :name "scripted"))

(defmethod http-protocol:send ((backend scripted-backend) client request &key)
  (declare (ignore client))
  (push (list (http-protocol:http-request-method request)
              (http-protocol:http-request-url request))
        (scripted-requests backend))
  (funcall (scripted-handler backend) request))

(defun respond (status body &key (content-type "application/json"))
  "An HTTP-RESPONSE with STATUS and BODY (a string, sent as UTF-8 octets)."
  (let ((headers (make-hash-table :test #'equal)))
    (setf (gethash "content-type" headers) content-type)
    (make-instance 'http-protocol:http-response
                   :status status :headers headers
                   :body (babel:string-to-octets body :encoding :utf-8))))

(defun call-with-scripted-backend (handler fn)
  "Call FN with a SCRIPTED-BACKEND running HANDLER as the HTTP backend, no
   host known to answer (*HOST-OUTCOMES*), and retries without sleeping. FN
   gets the backend."
  (let* ((backend (make-instance 'scripted-backend :handler handler))
         (http-protocol:*http-backend* backend)
         (cl-oci-client/http::*http-clients* '())
         (cl-oci-client/http:*host-outcomes* (make-hash-table :test 'equal))
         (*transport-retry* (make-instance 'cl-oci-client/http::transport-retry
                                           :total 3 :backoff-factor 0 :status nil
                                           :allowed-methods '(:get :head))))
    (funcall fn backend)))

(defun incomplete ()
  (error 'http-protocol:http-protocol-error :message "incomplete HTTP response"))

(deftest transport-failures-are-classified
  (ok (transport-failure-p (make-condition 'http-protocol:http-protocol-error
                                           :message "incomplete HTTP response")))
  (ok (transport-failure-p (make-condition 'http-protocol:http-timeout-error
                                           :message "sync await timed out")))
  (ok (transport-failure-p (make-condition 'http-protocol:http-connection-error)))
  (ok (transport-failure-p (make-condition 'http-protocol:http-tls-error)))
  (ok (transport-failure-p (make-condition 'end-of-file :stream *standard-input*)))
  (ng (transport-failure-p (make-condition 'http-protocol:unsupported-operation)))
  (ng (transport-failure-p (make-condition 'simple-error :format-control "x"))))

(deftest a-truncated-get-is-retried
  "#120: an incomplete response mid-pull, from a registry that has answered,
   is retried, and the retry's answer used."
  (let ((calls 0))
    (call-with-scripted-backend
     (lambda (request)
       (cond ((search "/v2/x/" (http-protocol:http-request-url request))
              (if (< (incf calls) 3) (incomplete) (respond 200 "blob")))
             (t (respond 200 "{}"))))
     (lambda (backend)
       (declare (ignore backend))
       (http-exchange :get "https://r.test/v2/")
       (multiple-value-bind (body status) (http-exchange :get "https://r.test/v2/x/blobs/d")
         (ok (= status 200))
         (ok (equal "blob" (babel:octets-to-string body))))
       (ok (= calls 3))))))

(deftest a-persistent-transport-failure-is-a-transport-error
  "#120/#132: after the retries the caller gets REGISTRY-TRANSPORT-ERROR naming
   the cause, not an answer it could read as \"not found\". The registry
   answered before, so the failure is retried; it is no REGISTRY-UNREACHABLE."
  (let ((calls 0))
    (call-with-scripted-backend
     (lambda (request)
       (cond ((search "/v2/x/" (http-protocol:http-request-url request))
              (incf calls)
              (error 'http-protocol:http-timeout-error :message "sync await timed out"))
             (t (respond 200 "{}"))))
     (lambda (backend)
       (declare (ignore backend))
       (http-exchange :get "https://r.test/v2/")
       (let ((e (handler-case (progn (http-exchange :get "https://r.test/v2/x/blobs/d") nil)
                  (registry-transport-error (e) e))))
         (ok e)
         (ok (not (typep e 'registry-unreachable)))
         (ok (= calls 4))
         (ok (= 4 (registry-transport-error-attempts e)))
         (ok (typep (registry-transport-error-cause e) 'http-protocol:http-timeout-error))
         (let ((report (princ-to-string e)))
           (ok (search "Network failure" report))
           (ok (search "sync await timed out" report))
           (ok (search "https://r.test/v2/x/blobs/d" report))))))))

(defun refused ()
  (error 'http-protocol:http-connection-error :message "connection refused"))

(deftest a-host-that-has-not-answered-gets-one-attempt
  "#179: retries are for a registry that answers. A refused first request is
   not retried: REGISTRY-UNREACHABLE. Later requests to that host are not
   sent at all; another host gets its own attempt."
  (call-with-scripted-backend
   (lambda (request) (declare (ignore request)) (refused))
   (lambda (backend)
     (let ((first (handler-case (progn (http-exchange :get "https://down.test/v2/a/tags/list") nil)
                    (registry-unreachable (e) e))))
       (ok first "REGISTRY-UNREACHABLE")
       (ok (= 1 (length (scripted-requests backend))) "one attempt")
       (ok (and first (registry-unreachable-sent-p first)))
       (ok (and first (equal "https://down.test" (registry-unreachable-host first))))
       (ok (eq :unreachable (host-state "https://down.test/v2/b/tags/list")))
       (let ((again (handler-case (progn (http-exchange :get "https://down.test/v2/b/tags/list") nil)
                      (registry-unreachable (e) e))))
         (ok again "REGISTRY-UNREACHABLE again")
         (ok (and again (not (registry-unreachable-sent-p again))) "not sent")
         (ok (= 1 (length (scripted-requests backend))) "still one request")
         (let ((report (princ-to-string again)))
           (ok (search "Registry https://down.test is unreachable" report) report)
           (ok (search "was not sent" report) report)
           (ok (search "connection refused" report) report))))
     (ok (signals (http-exchange :get "https://other.test/v2/") 'registry-unreachable))
     (ok (= 2 (length (scripted-requests backend))) "another host gets its own attempt"))))

(deftest an-unreachable-host-is-asked-again-after-a-while
  "#179: *UNREACHABLE-SECONDS* after its failure, a host gets one attempt
   again, and once it answers it is reachable."
  (let ((down t))
    (call-with-scripted-backend
     (lambda (request) (declare (ignore request)) (if down (refused) (respond 200 "{}")))
     (lambda (backend)
       (let ((*unreachable-seconds* 0))
         (ok (signals (http-exchange :get "https://r.test/v2/") 'registry-unreachable))
         (setf down nil)
         (ok (= 200 (nth-value 1 (http-exchange :get "https://r.test/v2/"))))
         (ok (= 2 (length (scripted-requests backend))))
         (ok (eq :reachable (host-state "https://r.test/"))))))))

(deftest a-registry-that-stops-answering-is-retried-once
  "#179: a host that answered gets the retries. When they all fail, its next
   request gets one attempt, and once that fails nothing more is sent."
  (let ((down nil))
    (call-with-scripted-backend
     (lambda (request) (declare (ignore request)) (if down (refused) (respond 200 "{}")))
     (lambda (backend)
       (http-exchange :get "https://r.test/v2/")
       (setf down t)
       (let ((e (handler-case (progn (http-exchange :get "https://r.test/v2/a/tags/list") nil)
                  (registry-transport-error (e) e))))
         (ok (and e (not (typep e 'registry-unreachable))) "a failure after the retries")
         (ok (= 5 (length (scripted-requests backend))) "the request and its three retries"))
       (ok (eq :unknown (host-state "https://r.test/")))
       (ok (signals (http-exchange :get "https://r.test/v2/b/tags/list") 'registry-unreachable))
       (ok (= 6 (length (scripted-requests backend))) "one attempt")
       (ok (signals (http-exchange :get "https://r.test/v2/c/tags/list") 'registry-unreachable))
       (ok (= 6 (length (scripted-requests backend))) "then none")))))

(deftest a-request-that-may-not-be-retried-keeps-the-host-reachable
  "A POST that fails on a registry that answers is not retried, and the
   registry stays reachable."
  (let ((down nil))
    (call-with-scripted-backend
     (lambda (request) (declare (ignore request)) (if down (incomplete) (respond 200 "{}")))
     (lambda (backend)
       (declare (ignore backend))
       (http-exchange :get "https://r.test/v2/")
       (setf down t)
       (ok (signals (http-exchange :post "https://r.test/v2/x/blobs/uploads/")
             'registry-transport-error))
       (ok (eq :reachable (host-state "https://r.test/")))))))

(deftest url-host-is-scheme-and-authority
  (ok (equal "https://ghcr.io" (url-host "https://ghcr.io/v2/ns/x/tags/list")))
  (ok (equal "http://127.0.0.1:9" (url-host "http://127.0.0.1:9/v2/")))
  (ok (equal "https://ghcr.io" (url-host "HTTPS://GHCR.IO?x=1")))
  (ok (equal "https://ghcr.io" (url-host "https://ghcr.io"))))

(deftest connecting-is-bounded-by-the-connect-timeout
  "#179: a black-holed host fails after *CONNECT-TIMEOUT*, not after the
   request's whole timeout (30 s, or an hour for a blob) on every attempt.
   A timeout that sets a connect phase keeps it."
  (flet ((phases (timeout)
           (let ((tm (http-protocol:coerce-timeout
                      (cl-oci-client/http::request-timeout timeout))))
             (list (http-protocol:timeout-connect tm) (http-protocol:timeout-total tm)))))
    (let ((*connect-timeout* 10)
          (old (uiop:getenv "CL_REPO_CONNECT_TIMEOUT")))
      (unwind-protect
          (progn
            (setf (uiop:getenv "CL_REPO_CONNECT_TIMEOUT") "")
            (destructuring-bind (connect total) (phases nil)
              (ok (= 10 connect) "no timeout: connect bounded")
              (ok (= 30 total) "and http-protocol's default total"))
            (destructuring-bind (connect total) (phases 3600)
              (ok (= 10 connect) "a blob's hour: connect bounded")
              (ok (= 3600 total)))
            (destructuring-bind (connect total) (phases 5)
              (ok (= 5 connect) "never more than the total")
              (ok (= 5 total)))
            (destructuring-bind (connect total) (phases '(:connect 3 :read 300))
              (ok (= 3 connect) "a connect phase is kept")
              (ok (null total)))
            (setf (uiop:getenv "CL_REPO_CONNECT_TIMEOUT") "0")
            (ok (null (first (phases nil))) "CL_REPO_CONNECT_TIMEOUT=0: no bound")
            (setf (uiop:getenv "CL_REPO_CONNECT_TIMEOUT") "4")
            (ok (= 4 (first (phases nil))) "CL_REPO_CONNECT_TIMEOUT=4"))
        (setf (uiop:getenv "CL_REPO_CONNECT_TIMEOUT") (or old ""))))))

(deftest only-idempotent-requests-are-retried
  (let ((calls 0))
    (call-with-scripted-backend
     (lambda (request) (declare (ignore request)) (incf calls) (incomplete))
     (lambda (backend)
       (declare (ignore backend))
       (ok (signals (http-exchange :post "https://r.test/v2/x/blobs/uploads/")
                    'registry-transport-error))
       (ok (= calls 1))))))

(deftest other-errors-are-not-retried-or-wrapped
  (let ((calls 0))
    (call-with-scripted-backend
     (lambda (request)
       (declare (ignore request))
       (incf calls)
       (error 'http-protocol:unsupported-operation :operation :stream-body))
     (lambda (backend)
       (declare (ignore backend))
       (ok (signals (http-exchange :get "https://r.test/v2/") 'http-protocol:unsupported-operation))
       (ok (= calls 1))))))

(deftest a-registry-status-is-not-a-transport-error
  "A 404 is the registry's answer: it reaches the caller as a status, once."
  (let ((calls 0))
    (call-with-scripted-backend
     (lambda (request) (declare (ignore request)) (incf calls) (respond 404 "{}"))
     (lambda (backend)
       (declare (ignore backend))
       (ok (= 404 (nth-value 1 (http-exchange :get "https://r.test/v2/x/tags/list"))))
       (ok (= calls 1))))))

;;; #131: error bodies are text, and OCI error documents print as code: message.

(defparameter +denied+
  "{\"errors\":[{\"code\":\"DENIED\",\"message\":\"requested access to the resource is denied\"}]}")

(deftest error-bodies-are-summarised
  (ok (equal "DENIED: requested access to the resource is denied"
             (error-body-summary (babel:string-to-octets +denied+))))
  (ok (equal "DENIED: requested access to the resource is denied"
             (error-body-summary +denied+)))
  (ok (equal "MANIFEST_UNKNOWN: manifest unknown; NAME_UNKNOWN"
             (error-body-summary
              "{\"errors\":[{\"code\":\"MANIFEST_UNKNOWN\",\"message\":\"manifest unknown\"},{\"code\":\"NAME_UNKNOWN\"}]}")))
  (ok (equal "upstream connect error" (error-body-summary (babel:string-to-octets "upstream connect error"))))
  (ok (equal "{not json" (error-body-summary "{not json")))
  (ok (null (error-body-summary nil)))
  (ok (null (error-body-summary ""))))

(deftest a-token-endpoint-403-prints-as-text
  "#131: ghcr answers 403 with a JSON body at the token endpoint; the error
   printed it as an octet vector, one number per line."
  (call-with-scripted-backend
   (lambda (request) (declare (ignore request)) (respond 403 +denied+))
   (lambda (backend)
     (declare (ignore backend))
     (let ((e (handler-case
                  (obtain-token "Bearer realm=\"https://r.test/token\",service=\"r.test\",scope=\"repository:ns/fiveam:pull\"")
                (auth-error (e) e))))
       (ok e)
       (ok (stringp (registry-error-body e)))
       (let ((report (princ-to-string e)))
         (ok (search "HTTP 403" report))
         (ok (search "DENIED: requested access to the resource is denied" report))
         (ng (search "#(" report)))))))

(deftest a-registry-error-body-prints-the-oci-error
  (call-with-scripted-backend
   (lambda (request) (declare (ignore request)) (respond 403 +denied+))
   (lambda (backend)
     (declare (ignore backend))
     (let ((report (handler-case (progn (registry-request (make-registry "https://r.test")
                                                          :get "/v2/ns/x/tags/list")
                                        "")
                     (auth-error (e) (princ-to-string e)))))
       (ok (search "DENIED: requested access to the resource is denied" report))
       (ng (search "123" report))))))
