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
                #:response-body
                #:http-connection-error
                #:http-timeout-error
                #:http-tls-error
                #:http-protocol-error
                #:unsupported-operation
                #:unsupported-content-coding
                #:http-retry
                #:make-http-retry
                #:retry-should-retry-p
                #:retry-delay-seconds
                #:make-http-request
                #:send-async
                #:coerce-timeout
                #:make-http-timeout
                #:timeout-connect
                #:timeout-read
                #:timeout-total)
  (:import-from :http #:request)
  (:import-from :bordeaux-threads #:make-lock #:with-lock-held)
  (:import-from :cl-oci-client/pin #:with-loaded-systems-pinned)
  (:import-from :cl-oci-client/conditions #:registry-transport-error #:registry-unreachable)
  (:export #:ensure-http-backend
           #:http-backend-kind
           #:http-exchange
           #:response-header-value
           #:transport-failure-p
           #:*transport-retry*
           #:*connect-timeout*
           #:*unreachable-seconds*
           #:*host-outcomes*
           #:host-state
           #:forget-host-outcomes
           #:url-host
           #:http-exchange-batch
           #:batch-concurrency))
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
   Linux, macOS and Windows.
   ABCL gets :DEXADOR: its sockets are Java objects with no OS descriptor, so
   the async backend loads but every request fails in register-io (\"cannot
   extract socket fd\"), which the load-failure fallback cannot catch
   (cl-repository#144)."
  #+abcl :dexador
  #-abcl :auto)

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
CL_REPO_HTTP_BACKEND=async). What loading the backend prints goes to
*ERROR-OUTPUT*: the caller's stdout is its own (cl-repository#194)."
  (or *http-backend*
      (let ((*standard-output* *error-output*))
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

(defvar *http-clients* '()
  "Clients HTTP-EXCHANGE reuses, one per (backend verify http-version), so a
   run of pulls shares one client and its connection pool instead of making a
   client per request.")

(defun %http-client (verify)
  (let* ((version (%registry-http-version))
         (key (list *http-backend* verify version)))
    (or (cdr (assoc key *http-clients* :test #'equal))
        (let ((client (make-http-client *http-backend* :verify verify
                                                       :http-version version)))
          (push (cons key client) *http-clients*)
          client))))

(defparameter *accept-encoding* '(:gzip :deflate)
  "Content-Encodings the client asks registries for. Only what
   http-encoding-chipz (pure Lisp, loaded by ENSURE-HTTP-BACKEND) decodes:
   :DEFAULT would probe every coding, load native codecs (brotli, zstd)
   mid-sync when the install tree has them, and warn about the others.")

(defun transport-failure-p (condition)
  "True when CONDITION means the request got no complete response: a
   connection, TLS or timeout failure, a truncated response (http-backend-async
   signals \"incomplete HTTP response\" as an HTTP-PROTOCOL-ERROR), or, on the
   dexador backend, a socket or stream error it lets through unwrapped. Not an
   unsupported operation or coding: retrying those cannot help."
  (flet ((named-type-p (package name)
           (let ((type (and (find-package package) (find-symbol name package))))
             (and type (typep condition type)))))
    (or (typep condition '(or http-connection-error http-timeout-error http-tls-error))
        (and (typep condition 'http-protocol-error)
             (not (typep condition '(or unsupported-operation unsupported-content-coding))))
        (typep condition 'stream-error)
        (named-type-p "USOCKET" "SOCKET-ERROR")
        (named-type-p "USOCKET" "NS-ERROR")
        (named-type-p "CL+SSL" "SSL-ERROR"))))

(defclass transport-retry (http-retry) ()
  (:documentation
   "http-protocol's retry policy, also retrying every TRANSPORT-FAILURE-P
    condition (a truncated response is an HTTP-PROTOCOL-ERROR, which the base
    policy does not retry) as a connection failure."))

(defmethod retry-should-retry-p ((retry transport-retry) attempt method
                                 &key status condition response)
  (if (and condition
           (transport-failure-p condition)
           (not (typep condition '(or http-connection-error http-timeout-error http-tls-error))))
      (call-next-method retry attempt method
                        :status status :response response
                        :condition (make-condition 'http-connection-error
                                                   :message (princ-to-string condition)))
      (call-next-method)))

(defvar *transport-retry*
  (make-instance 'transport-retry :total 3 :backoff-factor 1 :status nil
                                  :allowed-methods '(:get :head))
  "Retry policy HTTP-EXCHANGE applies to transport failures: three retries of a
   GET or HEAD after 1, 2 and 4 seconds. Response statuses are not retried
   here; callers decide what a 5xx means. NIL disables retries.")

(defvar *host-outcomes* (make-hash-table :test 'equal)
  "Host (URL-HOST) → what its last request came to: (:ANSWERED . time) or
   (:FAILED condition . time), in internal real time. HOST-STATE reads it.
   Retries are for a registry that answers: a host that has given no
   response yet gets one attempt per request, and when that fails requests
   to it fail at once for *UNREACHABLE-SECONDS* (or until it answers). An
   offline sync costs one failed round trip per registry, not retries with
   backoff for every package (cl-repository#179). Bind it to a fresh table
   to start from no knowledge (tests do).")

(defvar *host-outcomes-lock* (make-lock "cl-oci-client host outcomes"))

(defparameter *unreachable-seconds* 60
  "How long requests to a host whose request got no response fail at once
   (REGISTRY-UNREACHABLE, not sent), unless it answers meanwhile. After that
   its next request gets one attempt again.")

(defun url-host (url)
  "scheme://authority of URL, downcased: the requests of one registry share
   their host's state."
  (let* ((scheme-end (search "://" url))
         (start (if scheme-end (+ scheme-end 3) 0))
         (end (or (position-if (lambda (ch) (find ch "/?#")) url :start start)
                  (length url))))
    (string-downcase (subseq url 0 end))))

(defun %host-outcome (url)
  (with-lock-held (*host-outcomes-lock*)
    (gethash (url-host url) *host-outcomes*)))

(defun %set-host-outcome (url outcome)
  (with-lock-held (*host-outcomes-lock*)
    (if outcome
        (setf (gethash (url-host url) *host-outcomes*) outcome)
        (remhash (url-host url) *host-outcomes*))))

(defun host-state (url)
  "(values state cause) for the host of URL: :REACHABLE when its last request
   was answered (any HTTP status), :UNREACHABLE when its last one got no
   response less than *UNREACHABLE-SECONDS* ago (CAUSE: that failure), else
   :UNKNOWN."
  (let ((outcome (%host-outcome url)))
    (cond ((null outcome) :unknown)
          ((eq (car outcome) :answered) :reachable)
          ((< (/ (- (get-internal-real-time) (cddr outcome)) internal-time-units-per-second)
              *unreachable-seconds*)
           (values :unreachable (cadr outcome)))
          (t :unknown))))

(defun note-host-answered (url)
  (%set-host-outcome url (cons :answered (get-internal-real-time))))

(defun note-host-failure (url state condition &key retried)
  "Record that a request to the host of URL got no response (CONDITION). STATE
   is the host's HOST-STATE before the request. A host not known to answer is
   now unreachable. One that answered stays reachable after a single failed
   attempt (a request that may not be retried), and is :UNKNOWN after RETRIED
   attempts all failed: its next request gets one attempt."
  (cond ((not (eq state :reachable))
         (%set-host-outcome url (list* :failed condition (get-internal-real-time))))
        (retried (%set-host-outcome url nil))))

(defun forget-host-outcomes ()
  "Forget what requests to every host came to: each is :UNKNOWN again."
  (with-lock-held (*host-outcomes-lock*)
    (clrhash *host-outcomes*)))

(defparameter *connect-timeout* 10
  "Seconds a request may take to connect (TCP, proxy and TLS setup) when its
   timeout sets no connect phase. CL_REPO_CONNECT_TIMEOUT overrides it; 0
   leaves setup to the request's whole timeout. A host that never answers a
   connection (a black-holed address or network) fails in this time, not in
   the request's whole timeout (30 s, or an hour for a blob).")

(defun connect-timeout ()
  (let* ((v (uiop:getenv "CL_REPO_CONNECT_TIMEOUT"))
         (n (and v (plusp (length v)) (parse-integer v :junk-allowed t))))
    (if (and n (>= n 0))
        (and (plusp n) n)
        *connect-timeout*)))

(defun request-timeout (timeout)
  "TIMEOUT (NIL, seconds, a plist or an HTTP-TIMEOUT) with its connect phase
   bounded by CONNECT-TIMEOUT when it sets none. The other phases stay as
   they were: NIL is http-protocol's default total."
  (let ((connect (connect-timeout))
        (tm (coerce-timeout timeout)))
    (if (or (null connect) (timeout-connect tm))
        timeout
        (make-http-timeout :connect (if (timeout-total tm)
                                        (min connect (timeout-total tm))
                                        connect)
                           :read (timeout-read tm)
                           :total (timeout-total tm)))))

(defun %send-with-retry (method url retry thunk)
  "Call THUNK, retrying transport failures per RETRY while the host of URL
   is reachable (HOST-STATE). When they persist, signal
   REGISTRY-TRANSPORT-ERROR naming METHOD, URL and the last cause. A host not
   known to answer gets one attempt, and REGISTRY-UNREACHABLE when it fails;
   one that failed so lately gets none: REGISTRY-UNREACHABLE, not sent.
   Other errors are not caught: they keep their restarts."
  (multiple-value-bind (state cause) (host-state url)
    (when (eq state :unreachable)
      (error 'registry-unreachable :method method :url url :host (url-host url)
                                   :cause cause :attempts 0 :sent nil))
    (loop for attempt from 1
          do (handler-case (return (prog1 (funcall thunk) (note-host-answered url)))
               ((and error (satisfies transport-failure-p)) (e)
                 (unless (and retry
                              (eq state :reachable)
                              (retry-should-retry-p retry attempt method :condition e))
                   (note-host-failure url state e :retried (> attempt 1))
                   (if (eq state :reachable)
                       (error 'registry-transport-error
                              :method method :url url :cause e :attempts attempt)
                       (error 'registry-unreachable
                              :method method :url url :host (url-host url)
                              :cause e :attempts attempt)))
                 (sleep (retry-delay-seconds retry attempt)))))))

(defun http-request-kind (url)
  "The kind of registry request URL is, for tracing: :TAGS, :MANIFEST, :BLOB,
   :REFERRERS, :TOKEN or :OTHER."
  (cond ((search "/tags/list" url) :tags)
        ((search "/manifests/" url) :manifest)
        ((search "/blobs/" url) :blob)
        ((search "/referrers/" url) :referrers)
        ((search "token" url) :token)
        (t :other)))

(defun %trace-http-p ()
  (let ((v (uiop:getenv "CL_REPO_TRACE_HTTP")))
    (and v (plusp (length v)) (string/= v "0"))))

(defun %call-traced (method url thunk)
  "Call THUNK, one HTTP exchange returning an HTTP-RESPONSE. With
   CL_REPO_TRACE_HTTP set, log one line per exchange to *ERROR-OUTPUT*:
   \"; cl-repo-http KIND METHOD STATUS MS URL\" (STATUS is ERROR when no
   response came). Benchmarks count these lines by kind."
  (if (%trace-http-p)
      (let ((start (get-internal-real-time))
            (status "error"))
        (unwind-protect
             (let ((res (funcall thunk)))
               (setf status (response-status res))
               res)
          (format *error-output* "~&; cl-repo-http ~(~a ~a~) ~a ~d ~a~%"
                  (http-request-kind url) method status
                  (round (* 1000 (- (get-internal-real-time) start))
                         internal-time-units-per-second)
                  url)
          (force-output *error-output*)))
      (funcall thunk)))

(defun http-exchange (method url &key headers content (force-binary t) (verify t)
                             (decompress t) timeout (retry *transport-retry*))
  "Perform METHOD on URL via http-protocol.

   Returns (values body status response-headers) on any completed response
   (including 4xx/5xx) — call sites decide whether to challenge/auth or error.
   This matches Dexador's multi-value shape while using httpx-style non-raising
   defaults (:raise-for-status nil).

   A request that gets no complete response (TRANSPORT-FAILURE-P) is retried
   per RETRY (*TRANSPORT-RETRY*: GET and HEAD) while its host answers, and
   then signals REGISTRY-TRANSPORT-ERROR: callers must not read it as \"not
   found\" (#120, #132). A host that has not answered yet gets one attempt;
   when it fails, REGISTRY-UNREACHABLE, and requests to it are not sent for
   *UNREACHABLE-SECONDS* (#179, HOST-STATE).

   TIMEOUT (seconds, a plist or an HTTP-TIMEOUT) overrides the client's default
   for this request; http-backend-async applies it to the whole exchange, body
   included, so a large blob needs more than the 30 s default. Connecting
   takes at most CONNECT-TIMEOUT unless TIMEOUT sets a connect phase.
   Accept-Encoding is *ACCEPT-ENCODING*."
  ;; Pinned: a request may load a Content-Encoding backend, and must not
  ;; reload the client's own http-protocol from the install tree.
  (with-loaded-systems-pinned ()
    (ensure-http-backend)
    (let* ((client (%http-client verify))
           (timeout (request-timeout timeout))
           (res (%send-with-retry
                 method url retry
                 (lambda ()
                   (%call-traced
                    method url
                    (lambda ()
                      (request method url
                               :client client
                               :headers headers
                               :content content
                               :force-binary force-binary
                               :decompress decompress
                               :accept-encoding *accept-encoding*
                               :timeout timeout
                               :raise-for-status nil)))))))
      (values (response-body res)
              (response-status res)
              (response-headers res)))))

;;; Several exchanges at once, on one event loop
;;;
;;; Resolution asks a registry for dozens of tag lists and configs. One at a
;;; time, each waits a round trip. http-backend-async runs any number of
;;; requests on one loop; threads would not do, as every blocking request
;;; makes a libuv loop of its own and the libuv backend's handle tables are
;;; not safe across threads (event-backend-libuv#31).

(defparameter *batch-concurrency* 8
  "How many requests HTTP-EXCHANGE-BATCH keeps in flight. CL_REPO_FETCH_JOBS
   overrides it; 1 sends them one at a time.")

(defun batch-concurrency ()
  (let* ((v (uiop:getenv "CL_REPO_FETCH_JOBS"))
         (n (and v (plusp (length v)) (parse-integer v :junk-allowed t))))
    (max 1 (if (and n (plusp n)) n *batch-concurrency*))))

(defun %event (name)
  "Function NAME of event-protocol, loaded with the async backend only."
  (fdefinition (find-symbol name "EVENT-PROTOCOL")))

(defun %async-batch (requests concurrency)
  "HTTP-EXCHANGE-BATCH on the async backend. A request to a host that is
   unreachable (HOST-STATE) is not sent: its result is REGISTRY-UNREACHABLE.
   A failure is recorded as HTTP-EXCHANGE records it, so once a host that
   has not answered fails, the requests to it still queued are not sent."
  (let* ((n (length requests))
         (results (make-array n :initial-element nil))
         (done (make-array n :initial-element nil))
         (timers (make-array n :initial-element nil))
         (pending (loop for r in requests for i from 0 collect (cons i r)))
         (remaining n)
         (eb (funcall (symbol-value (find-symbol "*EVENT-BACKEND-MAKER*" "HTTP-BACKEND-ASYNC"))))
         (el (funcall (%event "MAKE-EVENT-LOOP") eb))
         (in-run nil))
    (labels ((finish (i value)
               (unless (aref done i)
                 (setf (aref done i) t
                       (aref results i) value)
                 (when (aref timers i)
                   (ignore-errors (funcall (%event "CANCEL") eb (aref timers i))))
                 (decf remaining)
                 (if (zerop remaining)
                     (funcall (%event "STOP") eb el)
                     (start-next))))
             (start-next ()
               (let ((job (pop pending)))
                 (when job
                   (destructuring-bind (i &key method url headers (verify t) timeout
                                          (force-binary t) (decompress t))
                       job
                     (multiple-value-bind (state cause) (host-state url)
                       (let ((start (get-internal-real-time)))
                         (labels ((trace-line (status)
                                    (when (%trace-http-p)
                                      (format *error-output* "~&; cl-repo-http ~(~a ~a~) ~a ~d ~a~%"
                                              (http-request-kind url) method status
                                              (round (* 1000 (- (get-internal-real-time) start))
                                                     internal-time-units-per-second)
                                              url)
                                      (force-output *error-output*)))
                                  (failed (c)
                                    (trace-line "error")
                                    (when (transport-failure-p c)
                                      (note-host-failure url state c))
                                    (finish i c)))
                           (if (eq state :unreachable)
                               (finish i (make-condition 'registry-unreachable
                                                         :method method :url url
                                                         :host (url-host url) :cause cause
                                                         :attempts 0 :sent nil))
                               (handler-case
                                   (progn
                                     (send-async
                                      *http-backend* (%http-client verify)
                                      (make-http-request :method method :url url
                                                         :headers headers
                                                         :force-binary force-binary
                                                         :decompress decompress
                                                         :accept-encoding *accept-encoding*
                                                         :timeout (request-timeout timeout)
                                                         :raise-for-status nil)
                                      :callback (lambda (res)
                                                  (trace-line (response-status res))
                                                  (note-host-answered url)
                                                  (finish i (list (response-body res)
                                                                  (response-status res)
                                                                  (response-headers res))))
                                      :error-callback #'failed)
                                     (unless (aref done i)
                                       (setf (aref timers i)
                                             (funcall (%event "SLEEP*") eb el
                                                      (if (realp timeout) timeout 30)
                                                      :callback
                                                      (lambda ()
                                                        (failed (make-condition
                                                                 'http-timeout-error
                                                                 :message "request timed out")))))))
                                 (error (e)
                                   (failed e))))))))))))
      (progv (list (find-symbol "*EVENT-BACKEND*" "EVENT-PROTOCOL")
                   (find-symbol "*EVENT-LOOP*" "EVENT-PROTOCOL"))
          (list eb el)
        (unwind-protect
            (progn
              (loop repeat concurrency while pending do (start-next))
              (when (plusp remaining)
                (setf in-run t)
                (funcall (%event "RUN") eb el :stop-when-idle nil)
                (setf in-run nil)))
          ;; never from an unwind out of RUN itself: libuv is mid-iteration
          (unless in-run
            (funcall (%event "CLOSE-EVENT-LOOP") eb el)))))
    (coerce results 'list)))

(defun http-exchange-batch (requests &key (concurrency (batch-concurrency)))
  "Perform REQUESTS, plists (:method :url :headers :verify :timeout
   :force-binary :decompress), up to CONCURRENCY at a time. Returns a list in
   the order of REQUESTS: per request (body status headers), or the condition
   it failed with. Nothing is retried here: a caller that wants
   HTTP-EXCHANGE's transport retries sends a failed request again through it.
   On the dexador backend, or with CONCURRENCY 1, the requests go through
   HTTP-EXCHANGE one at a time."
  (with-loaded-systems-pinned ()
    (ensure-http-backend)
    (if (and (eq *http-backend-kind* :async) (> concurrency 1) (cdr requests))
        (%async-batch requests concurrency)
        (mapcar (lambda (r)
                  (handler-case
                      (multiple-value-list
                       (http-exchange (getf r :method) (getf r :url)
                                      :headers (getf r :headers)
                                      :verify (getf r :verify t)
                                      :timeout (getf r :timeout)
                                      :force-binary (getf r :force-binary t)
                                      :decompress (getf r :decompress t)))
                    (error (e) e)))
                requests))))

;;; No backend is chosen at load time: choosing one loads systems, and doing
;;; that while ASDF is still loading this file is a recursive OPERATE ("Deprecated
;;; recursive use of ASDF/OPERATE:OPERATE"). The first HTTP-EXCHANGE binds it.
;;; Entry points (roswell/cl-repo.ros) call ENSURE-HTTP-BACKEND after loading
;;; the client, outside any ASDF operation.
