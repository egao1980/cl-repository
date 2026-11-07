;;;; Thin HTTP adapter over http-protocol.
;;;; Preserves the Dexador-era (values body status headers) contract used by
;;;; registry/auth/QL exporter, while matching cl-stack-http wire semantics.
;;;;
;;;; Backend: the cl-stack async backend on libuv (http-backend-async +
;;;; event-backend-libuv, TLS through cl-stack-ssl) whenever it loads;
;;;; http-backend-dexador otherwise. CL_REPO_HTTP_BACKEND=async|dexador forces one.
;;;; Dexador stays a declared dependency until setup-client can install the
;;;; libuv overlay the async stack needs on CI runners. cl-stack-ssl is a dependency
;;;; and loads first, so cl+ssl uses its OpenSSL whichever backend runs.

(defpackage :cl-oci-client/http
  (:use :cl)
  (:import-from :http-protocol
                #:*http-backend*
                #:make-http-client
                #:response-status
                #:response-headers
                #:response-body)
  (:import-from :http #:request)
  (:export #:ensure-http-backend
           #:http-backend-kind
           #:http-exchange
           #:response-header-value))
(in-package :cl-oci-client/http)

(defvar *http-backend-kind* nil
  ":ASYNC or :DEXADOR once ENSURE-HTTP-BACKEND chose a backend.")

(defun http-backend-kind () *http-backend-kind*)

(defun %env-backend ()
  (let ((v (uiop:getenv "CL_REPO_HTTP_BACKEND")))
    (cond ((or (null v) (string= v "") (string-equal v "auto")) :auto)
          ((string-equal v "async") :async)
          ((string-equal v "dexador") :dexador)
          (t (error "CL_REPO_HTTP_BACKEND must be async, dexador or auto, not ~S" v)))))

(defun %backend-load-failure-p (condition)
  "Failures that mean the async stack is not usable here (missing system,
missing native library), as opposed to bugs."
  (or (typep condition 'asdf:missing-component)
      (typep condition 'asdf:missing-dependency)
      (let ((cffi-error (and (find-package "CFFI")
                             (find-symbol "LOAD-FOREIGN-LIBRARY-ERROR" "CFFI"))))
        (and cffi-error (typep condition cffi-error)))))

(defun %make-async-backend ()
  ;; cl-stack-ssl first: it pins cl+ssl to its own OpenSSL when present
  (when (asdf:find-system "cl-stack-ssl" nil)
    (asdf:load-system "cl-stack-ssl"))
  (asdf:load-system "event-backend-libuv")
  (asdf:load-system "http-backend-async")
  (setf (symbol-value (find-symbol "*EVENT-BACKEND-MAKER*" "HTTP-BACKEND-ASYNC"))
        (symbol-function (find-symbol "MAKE-LIBUV-BACKEND" "EVENT-BACKEND-LIBUV")))
  (uiop:symbol-call :http-backend-async :make-async-backend))

(defun %make-dexador-backend ()
  (asdf:load-system "http-backend-dexador")
  (uiop:symbol-call :http-backend-dexador :make-dexador-backend))

(defun ensure-http-backend ()
  "Bind *HTTP-BACKEND* if unset: the async backend on libuv, or dexador when the
async stack cannot load here (restart USE-DEXADOR, taken automatically unless
CL_REPO_HTTP_BACKEND=async)."
  (or *http-backend*
      (progn
        ;; Load CE backend before first SEND so ASDF doesn't recurse mid-load.
        (asdf:load-system "http-encoding-chipz")
        (let ((choice (%env-backend)))
          (setf *http-backend*
                (if (eq choice :dexador)
                    (progn (setf *http-backend-kind* :dexador) (%make-dexador-backend))
                    (restart-case
                        (handler-bind ((error (lambda (c)
                                                (when (and (eq choice :auto) (%backend-load-failure-p c))
                                                  (warn "cl-repo: async HTTP backend unavailable (~A); using dexador" c)
                                                  (invoke-restart 'use-dexador)))))
                          (prog1 (%make-async-backend) (setf *http-backend-kind* :async)))
                      (use-dexador ()
                        :report "Use the dexador HTTP backend"
                        (setf *http-backend-kind* :dexador)
                        (%make-dexador-backend)))))))))

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
