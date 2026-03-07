(defpackage :cl-oci-client/conditions
  (:use :cl)
  (:export #:registry-error
           #:registry-error-status
           #:registry-error-body
           #:registry-error-url
           #:auth-error
           #:not-found-error
           #:upload-error))
(in-package :cl-oci-client/conditions)

(define-condition registry-error (error)
  ((status :initarg :status :reader registry-error-status :initform nil)
   (body :initarg :body :reader registry-error-body :initform nil)
   (url :initarg :url :reader registry-error-url :initform nil))
  (:report (lambda (c s)
             (format s "Registry error~@[ (HTTP ~a)~]~@[ at ~a~]~@[: ~a~]"
                     (registry-error-status c)
                     (registry-error-url c)
                     (registry-error-body c)))))

(define-condition auth-error (registry-error) ()
  (:report (lambda (c s)
             (format s "Authentication failed~@[ (HTTP ~a)~]~@[ at ~a~]"
                     (registry-error-status c)
                     (registry-error-url c)))))

(define-condition not-found-error (registry-error) ()
  (:report (lambda (c s)
             (format s "Not found~@[ at ~a~]" (registry-error-url c)))))

(define-condition upload-error (registry-error) ()
  (:report (lambda (c s)
             (format s "Upload failed~@[ (HTTP ~a)~]~@[ at ~a~]"
                     (registry-error-status c)
                     (registry-error-url c)))))
