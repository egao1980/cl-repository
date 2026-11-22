(defpackage :cl-oci-client/tests/transport-test
  (:use :cl :rove)
  (:import-from :cl-oci-client/http #:http-exchange #:*transport-retry* #:transport-failure-p)
  (:import-from :cl-oci-client/auth #:obtain-token)
  (:import-from :cl-oci-client/registry #:make-registry #:registry-request)
  (:import-from :cl-oci-client/conditions
                #:auth-error #:registry-error-body #:error-body-summary
                #:registry-transport-error #:registry-transport-error-attempts
                #:registry-transport-error-cause))
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
  "Call FN with a SCRIPTED-BACKEND running HANDLER as the HTTP backend, and
   retries without sleeping. FN gets the backend."
  (let* ((backend (make-instance 'scripted-backend :handler handler))
         (http-protocol:*http-backend* backend)
         (cl-oci-client/http::*http-clients* '())
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
  "#120: an incomplete response mid-pull is retried, and the retry's answer used."
  (let ((calls 0))
    (call-with-scripted-backend
     (lambda (request)
       (declare (ignore request))
       (if (< (incf calls) 3) (incomplete) (respond 200 "blob")))
     (lambda (backend)
       (declare (ignore backend))
       (multiple-value-bind (body status) (http-exchange :get "https://r.test/v2/x/blobs/d")
         (ok (= status 200))
         (ok (equal "blob" (babel:octets-to-string body))))
       (ok (= calls 3))))))

(deftest a-persistent-transport-failure-is-a-transport-error
  "#120/#132: after the retries the caller gets REGISTRY-TRANSPORT-ERROR naming
   the cause, not an answer it could read as \"not found\"."
  (let ((calls 0))
    (call-with-scripted-backend
     (lambda (request)
       (declare (ignore request))
       (incf calls)
       (error 'http-protocol:http-timeout-error :message "sync await timed out"))
     (lambda (backend)
       (declare (ignore backend))
       (let ((e (handler-case (progn (http-exchange :get "https://r.test/v2/x/blobs/d") nil)
                  (registry-transport-error (e) e))))
         (ok e)
         (ok (= calls 4))
         (ok (= 4 (registry-transport-error-attempts e)))
         (ok (typep (registry-transport-error-cause e) 'http-protocol:http-timeout-error))
         (let ((report (princ-to-string e)))
           (ok (search "Network failure" report))
           (ok (search "sync await timed out" report))
           (ok (search "https://r.test/v2/x/blobs/d" report))))))))

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
