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
  (%with-backend-env "bogus"
    (lambda ()
      (ok (signals (cl-oci-client/http:ensure-http-backend) 'error)))))
