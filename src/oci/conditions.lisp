(defpackage :cl-oci/conditions
  (:use :cl)
  (:export #:oci-error
           #:oci-parse-error
           #:oci-digest-mismatch
           #:oci-invalid-media-type
           #:oci-error-message))
(in-package :cl-oci/conditions)

(define-condition oci-error (error)
  ((message :initarg :message :reader oci-error-message))
  (:report (lambda (c s) (format s "OCI error: ~a" (oci-error-message c)))))

(define-condition oci-parse-error (oci-error) ()
  (:report (lambda (c s) (format s "OCI parse error: ~a" (oci-error-message c)))))

(define-condition oci-digest-mismatch (oci-error)
  ((expected :initarg :expected :reader expected-digest)
   (actual :initarg :actual :reader actual-digest))
  (:report (lambda (c s)
             (format s "OCI digest mismatch: expected ~a, got ~a"
                     (expected-digest c) (actual-digest c)))))

(define-condition oci-invalid-media-type (oci-error)
  ((media-type :initarg :media-type :reader invalid-media-type))
  (:report (lambda (c s)
             (format s "Invalid OCI media type: ~a" (invalid-media-type c)))))
