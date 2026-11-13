;;;; Thin HTTP adapter over http-protocol.
;;;; Preserves the Dexador-era (values body status headers) contract used by
;;;; registry/auth/QL exporter, while matching cl-stack-http wire semantics.
;;;;
;;;; Backend: http-backend-dexador by default (see %DEFAULT-BACKEND-CHOICE);
;;;; CL_REPO_HTTP_BACKEND=auto uses the cl-stack async backend on libuv
;;;; (http-backend-async + event-backend-libuv, TLS through cl-stack-ssl) when
;;;; it loads, =async requires it, =dexador forces dexador.
;;;; The client package ships the async stack (qlfile seeds for setup-client,
;;;; which pulls the libuv overlay per platform). Dexador stays as the fallback
;;;; for platforms without that overlay. cl-stack-ssl is a dependency
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
  (:import-from :cl-oci-client/pin #:with-loaded-systems-pinned)
  (:export #:ensure-http-backend
           #:http-backend-kind
           #:http-exchange
           #:response-header-value))
(in-package :cl-oci-client/http)

(defvar *http-backend-kind* nil
  ":ASYNC or :DEXADOR once ENSURE-HTTP-BACKEND chose a backend.")

(defun http-backend-kind () *http-backend-kind*)

(defun %default-backend-choice ()
  "The backend when CL_REPO_HTTP_BACKEND is unset: :AUTO, the async backend on
   libuv, or dexador when the async stack cannot load here.
   CL_REPO_HTTP_BACKEND=dexador keeps 0.27.4's dexador everywhere.
   0.27.6–0.27.12 defaulted to dexador: http-backend-async 0.2.14 hung on HEAD
   responses (fixed in 0.2.15), and code under test shared the client's image,
   where cl+ssl could open an OpenSSL other than cl-stack-ssl's (tests run in
   a fresh image since 0.27.12; http-backend-async 0.2.16 loads cl-stack-ssl
   before cl+ssl). The checkout-client-async CI job runs this default on
   Linux, macOS and Windows."
  :auto)

(defun %env-backend ()
  (let ((v (uiop:getenv "CL_REPO_HTTP_BACKEND")))
    (cond ((or (null v) (string= v "")) (%default-backend-choice))
          ((string-equal v "auto") :auto)
          ((string-equal v "async") :async)
          ((string-equal v "dexador") :dexador)
          (t (error "CL_REPO_HTTP_BACKEND must be async, dexador or auto, not ~S" v)))))

(defun %backend-load-failure-p (condition)
  "Failures that mean the async stack cannot be loaded here (missing system,
missing native library, a grovel or compile step that cannot run, e.g. a git
checkout of event-backend-libuv without its grovel cache or headers), as
opposed to bugs in it at run time."
  (or (typep condition 'asdf:missing-component)
      (typep condition 'asdf:missing-dependency)
      (typep condition 'asdf:load-system-definition-error)
      (typep condition 'uiop:compile-file-error)
      (typep condition 'uiop:compile-warned-error)
      (flet ((named-type-p (package name)
               (let ((type (and (find-package package) (find-symbol name package))))
                 (and type (typep condition type)))))
        (or (named-type-p "CFFI" "LOAD-FOREIGN-LIBRARY-ERROR")
            ;; event-backend-libuv's (:native-library "uv") with no libuv anywhere
            (named-type-p "ASDF-NATIVE" "NATIVE-LIBRARY-NOT-FOUND")
            (named-type-p "CFFI-GROVEL" "GROVEL-ERROR")))))

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
        ;; Load CE backend before first SEND so a request never loads one mid-plan.
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

(defun %registry-http-version ()
  "HTTP/2 only when http2 is already loaded in this image. The client package
   does not ship http2: offering h2 without it made GHCR pick h2 and every
   request fail (http-backend-async 0.2.14 on the 0.27.5 ci-base image)."
  (if (find-package "HTTP2/CLIENT") :auto :http/1.1))

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
  ;; Pinned: a request may load a Content-Encoding backend, and must not
  ;; reload the client's own http-protocol from the install tree.
  (with-loaded-systems-pinned ()
    (ensure-http-backend)
    (let* ((client (make-http-client *http-backend* :verify verify
                                                    :http-version (%registry-http-version)))
           (res (request method url
                         :client client
                         :headers headers
                         :content content
                         :force-binary force-binary
                         :decompress decompress
                         :raise-for-status nil)))
      (values (response-body res)
              (response-status res)
              (response-headers res)))))

;;; No backend is chosen at load time: choosing one loads systems, and doing
;;; that while ASDF is still loading this file is a recursive OPERATE ("Deprecated
;;; recursive use of ASDF/OPERATE:OPERATE"). The first HTTP-EXCHANGE binds it.
;;; Entry points (roswell/cl-repo.ros) call ENSURE-HTTP-BACKEND after loading
;;; the client, outside any ASDF operation.
