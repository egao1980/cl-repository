(defpackage :cl-oci-client/tests/registry-test
  (:use :cl :rove)
  (:import-from :cl-oci-client/registry #:make-registry #:registry-url #:parse-reference))
(in-package :cl-oci-client/tests/registry-test)

(deftest make-registry-basic
  (let ((r (make-registry "ghcr.io")))
    (ok (string= (registry-url r) "ghcr.io"))))

(deftest make-registry-strip-trailing-slash
  (let ((r (make-registry "https://registry.example.com/")))
    (ok (string= (registry-url r) "https://registry.example.com"))))

(deftest parse-reference-with-tag
  (multiple-value-bind (host repo tag) (parse-reference "ghcr.io/cl-systems/alexandria:1.4")
    (ok (string= host "ghcr.io"))
    (ok (string= repo "cl-systems/alexandria"))
    (ok (string= tag "1.4"))))

(deftest parse-reference-with-digest
  (multiple-value-bind (host repo digest) (parse-reference "ghcr.io/ns/foo@sha256:abcdef")
    (ok (string= host "ghcr.io"))
    (ok (string= repo "ns/foo"))
    (ok (string= digest "sha256:abcdef"))))

(deftest parse-reference-no-host
  (multiple-value-bind (host repo tag) (parse-reference "library/ubuntu:latest")
    (ok (null host))
    (ok (string= repo "library/ubuntu"))
    (ok (string= tag "latest"))))

(deftest parse-reference-default-tag
  (multiple-value-bind (host repo tag) (parse-reference "ghcr.io/ns/foo")
    (ok (string= host "ghcr.io"))
    (ok (string= repo "ns/foo"))
    (ok (string= tag "latest"))))

(defun %with-backend-env (value thunk)
  (let ((old (uiop:getenv "CL_REPO_HTTP_BACKEND"))
        (http-protocol:*http-backend* nil))
    (unwind-protect
         (progn (setf (uiop:getenv "CL_REPO_HTTP_BACKEND") value)
                (funcall thunk))
      (setf (uiop:getenv "CL_REPO_HTTP_BACKEND") (or old "")))))

(deftest http-backend-selection
  ;; explicit dexador
  (%with-backend-env "dexador"
    (lambda ()
      (ok (cl-oci-client/http:ensure-http-backend))
      (ok (eq :dexador (cl-oci-client/http:http-backend-kind)))))
  ;; auto: the async stack when it loads here, else dexador
  (%with-backend-env "auto"
    (lambda ()
      (ok (cl-oci-client/http:ensure-http-backend))
      (ok (member (cl-oci-client/http:http-backend-kind) '(:async :dexador)))))
  ;; unset: the same as auto
  (ok (eq :auto (cl-oci-client/http::%default-backend-choice)))
  (%with-backend-env "bogus"
    (lambda ()
      (ok (signals (cl-oci-client/http:ensure-http-backend) 'error)))))

(deftest http-exchange-reuses-its-client
  ;; One client per (backend verify http-version): a run of pulls shares one
  ;; client and its connection pool, not a client per request.
  (%with-backend-env "dexador"
    (lambda ()
      (let ((cl-oci-client/http::*http-clients* '()))
        (cl-oci-client/http:ensure-http-backend)
        (let ((a (cl-oci-client/http::%http-client t))
              (b (cl-oci-client/http::%http-client t))
              (c (cl-oci-client/http::%http-client nil)))
          (ok (eq a b))
          (ok (not (eq a c)))
          (ok (= 2 (length cl-oci-client/http::*http-clients*))))))))

(deftest blob-timeout-reads-the-environment
  (let ((old (uiop:getenv "CL_REPO_BLOB_TIMEOUT")))
    (unwind-protect
        (progn
          (setf (uiop:getenv "CL_REPO_BLOB_TIMEOUT") "")
          (ok (= cl-oci-client/registry::*blob-timeout*
                 (cl-oci-client/registry:blob-timeout)))
          (setf (uiop:getenv "CL_REPO_BLOB_TIMEOUT") "90")
          (ok (= 90 (cl-oci-client/registry:blob-timeout)))
          (setf (uiop:getenv "CL_REPO_BLOB_TIMEOUT") "soon")
          (ok (= cl-oci-client/registry::*blob-timeout*
                 (cl-oci-client/registry:blob-timeout))))
      (setf (uiop:getenv "CL_REPO_BLOB_TIMEOUT") (or old "")))))

(deftest blob-transfers-get-the-blob-timeout
  ;; http-backend-async times the whole exchange: a blob PUT or GET with the
  ;; 30 s default failed llama-cpp's 1 GB CUDA layer. The upload POST and
  ;; other small requests keep the client default (NIL here).
  (let* ((calls '())
         (old (fdefinition 'cl-oci-client/http:http-exchange))
         (reg (make-registry "https://registry.example")))
    (unwind-protect
        (progn
          (setf (fdefinition 'cl-oci-client/http:http-exchange)
                (lambda (method url &key timeout &allow-other-keys)
                  (declare (ignore url))
                  (push (cons method timeout) calls)
                  (let ((h (make-hash-table :test 'equal)))
                    (ecase method
                      (:post (setf (gethash "location" h)
                                   "https://registry.example/v2/x/blobs/uploads/1")
                       (values nil 202 h))
                      (:put (values nil 201 h))
                      (:get (values (make-array 1 :element-type '(unsigned-byte 8)) 200 h))))))
          (cl-oci-client/push:push-blob-monolithic
           reg "x" (make-array 1 :element-type '(unsigned-byte 8)) "sha256:00")
          (cl-oci-client/pull:pull-blob reg "x" "sha256:00"))
      (setf (fdefinition 'cl-oci-client/http:http-exchange) old))
    (let ((blob (cl-oci-client/registry:blob-timeout)))
      (ok (equal (list (cons :post nil) (cons :put blob) (cons :get blob))
                 (reverse calls))))))
