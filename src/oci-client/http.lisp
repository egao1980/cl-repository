;;;; Thin HTTP adapter over http-protocol + http-backend-dexador.
;;;; Preserves the Dexador-era (values body status headers) contract used by
;;;; registry/auth/QL exporter, while matching cl-stack-http wire semantics.

(defpackage :cl-oci-client/http
  (:use :cl)
  (:import-from :http-protocol
                #:*http-backend*
                #:make-http-client
                #:response-status
                #:response-headers
                #:response-body)
  (:import-from :http #:request)
  (:import-from :http-backend-dexador #:make-dexador-backend)
  (:export #:ensure-http-backend
           #:http-exchange
           #:response-header-value))
(in-package :cl-oci-client/http)

(defun ensure-http-backend ()
  "Bind *HTTP-BACKEND* to the dexador sync backend if unset.
   Same default as cl-stack-http :auto on non-Windows."
  (or *http-backend*
      (progn
        ;; Load CE backend before first SEND so ASDF doesn't recurse mid-load.
        (asdf:load-system "http-encoding-chipz")
        (setf *http-backend* (make-dexador-backend)))))

(defun response-header-value (headers name)
  "Lookup NAME in a response header hash-table (lowercase EQUAL keys)."
  (when headers
    (gethash (string-downcase name) headers)))

(defun http-exchange (method url &key headers content (force-binary t) (verify t)
                                   (decompress t))
  "Perform METHOD on URL via http-protocol.

   Returns (values body status response-headers) on any completed response
   (including 4xx/5xx) — call sites decide whether to challenge/auth or error.
   This matches Dexador's multi-value shape while using httpx-style non-raising
   defaults (:raise-for-status nil)."
  (ensure-http-backend)
  (let* ((client (make-http-client *http-backend* :verify verify))
         (res (request method url
                       :client client
                       :headers headers
                       :content content
                       :force-binary force-binary
                       :decompress decompress
                       :raise-for-status nil)))
    (values (response-body res)
            (response-status res)
            (response-headers res))))

;;; Bind a default backend at load so package-inferred consumers don't need
;;; an explicit setup call before the first registry request.
(ensure-http-backend)
