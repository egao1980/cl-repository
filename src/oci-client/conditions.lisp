(defpackage :cl-oci-client/conditions
  (:use :cl)
  (:import-from :babel #:octets-to-string)
  (:import-from :yason)
  (:export #:registry-error
           #:registry-error-status
           #:registry-error-body
           #:registry-error-url
           #:auth-error
           #:not-found-error
           #:upload-error
           #:error-body-text
           #:error-body-summary
           #:registry-transport-error
           #:registry-transport-error-method
           #:registry-transport-error-url
           #:registry-transport-error-cause
           #:registry-transport-error-attempts))
(in-package :cl-oci-client/conditions)

(defun error-body-text (body)
  "BODY of a failed HTTP response as text. Registries answer errors with a
   JSON document; a request that forces binary hands back octets, which
   printed as a vector of hundreds of numbers (#131)."
  (if (typep body '(vector (unsigned-byte 8)))
      (octets-to-string body :encoding :utf-8 :errorp nil)
      body))

(defun %oci-error-entries (text)
  "The errors[] entries of an OCI distribution error document TEXT, or NIL
   when TEXT is not one."
  (let ((json (and (stringp text)
                   (let ((trimmed (string-left-trim '(#\Space #\Tab #\Newline #\Return) text)))
                     (and (plusp (length trimmed)) (char= #\{ (char trimmed 0))))
                   (ignore-errors (yason:parse text)))))
    (when (hash-table-p json)
      (let ((errors (gethash "errors" json)))
        (when (listp errors)
          (remove-if-not #'hash-table-p errors))))))

(defun error-body-summary (body)
  "Short text for an error BODY: the OCI errors[].code / message pairs when
   it is an OCI error document (\"DENIED: requested access to the resource is
   denied\"), else the body decoded as UTF-8. NIL for an empty body."
  (let* ((text (error-body-text body))
         (entries (%oci-error-entries text)))
    (cond
      (entries
       (format nil "~{~a~^; ~}"
               (mapcar (lambda (e)
                         (let ((code (gethash "code" e))
                               (message (gethash "message" e)))
                           (format nil "~@[~a~]~:[~;: ~]~@[~a~]"
                                   code (and code message) message)))
                       entries)))
      ((stringp text) (and (plusp (length text)) text))
      ((null text) nil)
      (t (princ-to-string text)))))

(define-condition registry-error (error)
  ((status :initarg :status :reader registry-error-status :initform nil)
   (body :initarg :body :reader registry-error-body :initform nil)
   (url :initarg :url :reader registry-error-url :initform nil))
  (:report (lambda (c s)
             (format s "Registry error~@[ (HTTP ~a)~]~@[ at ~a~]~@[: ~a~]"
                     (registry-error-status c)
                     (registry-error-url c)
                     (error-body-summary (registry-error-body c))))))

(define-condition auth-error (registry-error) ()
  (:report (lambda (c s)
             (format s "Authentication failed~@[ (HTTP ~a)~]~@[ at ~a~]~@[: ~a~]"
                     (registry-error-status c)
                     (registry-error-url c)
                     (error-body-summary (registry-error-body c))))))

(define-condition not-found-error (registry-error) ()
  (:report (lambda (c s)
             (format s "Not found~@[ at ~a~]" (registry-error-url c)))))

(define-condition upload-error (registry-error) ()
  (:report (lambda (c s)
             (format s "Upload failed~@[ (HTTP ~a)~]~@[ at ~a~]"
                     (registry-error-status c)
                     (registry-error-url c)))))

(define-condition registry-transport-error (error)
  ((method :initarg :method :reader registry-transport-error-method :initform nil)
   (url :initarg :url :reader registry-transport-error-url :initform nil)
   (cause :initarg :cause :reader registry-transport-error-cause :initform nil)
   (attempts :initarg :attempts :reader registry-transport-error-attempts :initform 1))
  (:documentation
   "A request that got no complete HTTP response: connection, TLS, timeout or
    a truncated response, after the client's retries. Not a REGISTRY-ERROR: the
    registry gave no answer, so it says nothing about whether a package exists.")
  (:report (lambda (c s)
             (format s "Network failure: ~@[~a ~]~@[~a ~]failed~@[ after ~d attempts~]~@[: ~a~]"
                     (registry-transport-error-method c)
                     (registry-transport-error-url c)
                     (let ((n (registry-transport-error-attempts c)))
                       (and n (> n 1) n))
                     (registry-transport-error-cause c)))))
