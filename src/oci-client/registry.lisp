(defpackage :cl-oci-client/registry
  (:use :cl)
  (:import-from :cl-oci-client/conditions #:registry-error #:auth-error #:not-found-error
                #:error-body-text)
  (:import-from :bordeaux-threads #:make-lock #:with-lock-held)
  (:import-from :cl-oci-client/auth
                #:auth-config #:auth-config-token #:make-auth-config
                #:obtain-token #:make-auth-headers #:token-request #:parse-token-response
                #:parse-www-authenticate)
  (:import-from :cl-oci-client/http
                #:http-exchange #:response-header-value #:http-exchange-batch
                #:http-backend-kind #:batch-concurrency #:transport-failure-p
                #:ensure-http-backend)
  (:import-from :cl-oci-client/conditions #:registry-transport-error)
  (:export #:registry
           #:signal-registry-error
           #:registry-url
           #:registry-auth
           #:registry-insecure-p
           #:make-registry
           #:ping
           #:registry-request
           #:registry-request-batch
           #:parse-reference
           #:blob-timeout
           #:clear-token-cache
           #:*token-cache-enabled*))
(in-package :cl-oci-client/registry)

(defclass registry ()
  ((url :type string :initarg :url :accessor registry-url)
   (auth :type (or null auth-config) :initarg :auth :accessor registry-auth :initform nil)
   (insecure-p :type boolean :initarg :insecure-p :accessor registry-insecure-p :initform nil)))

(defun make-registry (url &key auth insecure-p)
  (make-instance 'registry
                 :url (string-right-trim "/" url)
                 :auth auth
                 :insecure-p insecure-p))

(defun base-url (registry)
  (let ((url (registry-url registry)))
    (if (or (search "://" url) (registry-insecure-p registry))
        url
        (format nil "https://~a" url))))

(defun api-url (registry path)
  "Construct full API URL. If PATH is already absolute (contains ://), use as-is."
  (if (search "://" path)
      path
      (format nil "~a~a" (base-url registry) path)))

(defun %verify (registry)
  (not (registry-insecure-p registry)))

;;; Bearer tokens per repository, shared by every REGISTRY object in the
;;; image. The client makes a fresh REGISTRY per lookup, so without this each
;;; request was GET → 401 → token GET → GET again: three exchanges for one.

(defvar *token-cache-enabled* t
  "When true, REGISTRY-REQUEST reuses a bearer token obtained for the same
   registry and repository until it expires.")

(defvar *token-cache* (make-hash-table :test 'equal)
  "(base-url repository username) → (token . expiry-universal-time).")

(defvar *token-cache-lock* (make-lock "cl-oci-client token cache"))

(defvar *token-realms* (make-hash-table :test 'equal)
  "base-url → (realm . service) of the registry's bearer challenges. A
   batch asks for the tokens of repositories on it before their requests,
   instead of learning each from a 401.")

(defparameter *default-token-lifetime* 240
  "Seconds a token without expires_in is reused. A token the registry no
   longer accepts costs one 401 and a fresh challenge, so this only bounds
   how long a stale one is tried first.")

(defun clear-token-cache ()
  "Forget every remembered token and token realm."
  (with-lock-held (*token-cache-lock*)
    (clrhash *token-cache*)
    (clrhash *token-realms*)))

(defun path-repository (path)
  "The repository of a /v2/<repository>/<endpoint>/... PATH, or NIL."
  (when (and (> (length path) 4) (string= "/v2/" path :end2 4))
    (let ((end nil))
      (dolist (endpoint '("/tags/" "/manifests/" "/blobs/" "/referrers/"))
        (let ((pos (search endpoint path :start2 4)))
          (when (and pos (> pos 4) (or (null end) (< pos end)))
            (setf end pos))))
      (and end (subseq path 4 end)))))

(defun %token-key (registry path)
  (let ((repo (path-repository path)))
    (when repo
      (list (base-url registry) repo
            (let ((auth (registry-auth registry)))
              (and auth (cl-oci-client/auth:auth-config-username auth)))))))

(defun token-cache-enabled-p ()
  "*TOKEN-CACHE-ENABLED*, unless CL_REPO_TOKEN_CACHE is 0."
  (and *token-cache-enabled*
       (not (equal (uiop:getenv "CL_REPO_TOKEN_CACHE") "0"))))

(defun cached-token (registry path)
  "A live bearer token remembered for PATH's repository, or NIL."
  (when (token-cache-enabled-p)
    (let ((key (%token-key registry path)))
      (when key
        (with-lock-held (*token-cache-lock*)
          (let ((entry (gethash key *token-cache*)))
            (cond ((null entry) nil)
                  ((< (get-universal-time) (cdr entry)) (car entry))
                  (t (remhash key *token-cache*) nil))))))))

(defun remember-token (registry path token expires-in)
  (let ((key (%token-key registry path)))
    (when (and key token (token-cache-enabled-p))
      ;; 90% of the lifetime: a token is not sent in its last seconds
      (let ((ttl (floor (* 9 (or expires-in *default-token-lifetime*)) 10)))
        (with-lock-held (*token-cache-lock*)
          (setf (gethash key *token-cache*)
                (cons token (+ (get-universal-time) (max 1 ttl)))))))))

(defun request-auth-headers (registry path)
  "Authorization for a request to PATH: the registry's own token, else a
   cached token for the repository, else the registry's credentials (Basic)."
  (let ((auth (registry-auth registry)))
    (or (and auth (auth-config-token auth) (make-auth-headers auth))
        (let ((token (cached-token registry path)))
          (and token (list (cons "Authorization" (format nil "Bearer ~a" token)))))
        (make-auth-headers auth))))

(defun note-token-realm (registry www-authenticate)
  (let* ((params (ignore-errors (parse-www-authenticate www-authenticate)))
         (realm (and params (gethash "realm" params))))
    (when realm
      (with-lock-held (*token-cache-lock*)
        (setf (gethash (base-url registry) *token-realms*)
              (cons realm (gethash "service" params)))))))

(defun predicted-challenge (registry path)
  "The challenge a pull from PATH's repository would get, when the
   registry's realm is known and it is asked without credentials."
  (let ((realm (with-lock-held (*token-cache-lock*)
                 (gethash (base-url registry) *token-realms*)))
        (repo (path-repository path)))
    (when (and realm repo (null (registry-auth registry)))
      (format nil "Bearer realm=\"~a\",service=\"~a\",scope=\"repository:~a:pull\""
              (car realm) (or (cdr realm) "") repo))))

(defun handle-auth-challenge (registry headers &optional path)
  "Handle 401 by extracting WWW-Authenticate and obtaining a token.
   The token is remembered for PATH's repository (REMEMBER-TOKEN)."
  (let ((www-auth (response-header-value headers "www-authenticate")))
    (when www-auth
      (note-token-realm registry www-auth)
      (multiple-value-bind (token expires-in)
          (obtain-token www-auth
                        :auth (registry-auth registry)
                        :insecure (registry-insecure-p registry))
        (when path (remember-token registry path token expires-in))
        (if (registry-auth registry)
            (setf (auth-config-token (registry-auth registry)) token)
            (setf (registry-auth registry) (make-auth-config :token token)))
        t))))

(defun signal-registry-error (status url body)
  "Signal the REGISTRY-ERROR subtype for HTTP STATUS: AUTH-ERROR for 401/403,
   NOT-FOUND-ERROR for 404, REGISTRY-ERROR otherwise."
  (error (case status
           ((401 403) 'auth-error)
           (404 'not-found-error)
           (t 'registry-error))
         :status status :url url :body (error-body-text body)))

(defun ping (registry)
  "Check if the registry supports OCI Distribution Spec (GET /v2/)."
  (let ((url (api-url registry "/v2/")))
    (multiple-value-bind (body status headers)
        (http-exchange :get url
                       :headers (make-auth-headers (registry-auth registry))
                       :force-binary nil
                       :verify (%verify registry))
      (declare (ignorable body))
      (cond
        ((<= 200 status 299) t)
        ((= status 401)
         (handle-auth-challenge registry headers))
        (t (signal-registry-error status url body))))))

(defvar *blob-timeout* 3600
  "Seconds a blob GET or PUT may take, body included; CL_REPO_BLOB_TIMEOUT
   overrides it. http-backend-async times the whole exchange, so its 30 s default
   fails a CUDA overlay layer (about 1 GB) even on a fast link.")

(defun blob-timeout ()
  "*BLOB-TIMEOUT*, or CL_REPO_BLOB_TIMEOUT when that is a positive integer."
  (let* ((v (uiop:getenv "CL_REPO_BLOB_TIMEOUT"))
         (n (and v (plusp (length v)) (parse-integer v :junk-allowed t))))
    (if (and n (plusp n)) n *blob-timeout*)))

(defun registry-request (registry method path &key content content-type headers
                                  accept (handle-auth t) timeout)
  "Make an authenticated HTTP request to the registry.
   TIMEOUT overrides the HTTP client's default (see BLOB-TIMEOUT).
   Returns (values body status response-headers)."
  (let* ((url (api-url registry path))
         (auth-hdrs (request-auth-headers registry path))
         (all-headers (append auth-hdrs
                              (when content-type
                                (list (cons "Content-Type" content-type)))
                              (when accept
                                (list (cons "Accept" accept)))
                              headers)))
    (multiple-value-bind (body status resp-headers)
        (http-exchange method url
                       :headers all-headers
                       :content content
                       :force-binary t
                       :verify (%verify registry)
                       ;; Blobs/manifests are opaque octets — don't CE-decode.
                       :decompress nil
                       :timeout timeout)
      (cond
       ((<= 200 status 299)
        (values body status resp-headers))
       ((and handle-auth (= status 401))
        (handle-auth-challenge registry resp-headers path)
        (registry-request registry method path
                          :content content :content-type content-type
                          :headers headers :accept accept :handle-auth nil
                          :timeout timeout))
       (t (signal-registry-error status url body))))))

(defun parse-reference (reference)
  "Parse a reference like 'ghcr.io/namespace/name:tag' or 'registry/name@sha256:...'
   Returns (values registry-host repository tag-or-digest)."
  (let* ((at-pos (position #\@ reference))
         (colon-pos (and (not at-pos) (position #\: reference :from-end t))))
    (multiple-value-bind (repo-part ref-part)
        (cond
          (at-pos (values (subseq reference 0 at-pos) (subseq reference (1+ at-pos))))
          (colon-pos (values (subseq reference 0 colon-pos) (subseq reference (1+ colon-pos))))
          (t (values reference "latest")))
      (let ((slash-pos (position #\/ repo-part)))
        (if (and slash-pos
                 (or (search "." (subseq repo-part 0 slash-pos))
                     (search ":" (subseq repo-part 0 slash-pos))
                     (string= "localhost" (subseq repo-part 0 slash-pos))))
            (values (subseq repo-part 0 slash-pos)
                    (subseq repo-part (1+ slash-pos))
                    ref-part)
            (values nil repo-part ref-part))))))

;;; Many requests at once

(defun %captured-request (registry method path &rest keys)
  "REGISTRY-REQUEST, its values as a list, or the error it signalled."
  (handler-case (multiple-value-list (apply #'registry-request registry method path keys))
    (error (e) e)))

(defun %http-request-plist (registry method path accept timeout)
  (list :method method
        :url (api-url registry path)
        :headers (append (request-auth-headers registry path)
                         (when accept (list (cons "Accept" accept))))
        :verify (%verify registry)
        :timeout timeout
        :force-binary t
        :decompress nil))

(defun %fetch-tokens (challenges)
  "CHALLENGES: ((registry path www-authenticate) ...). Requests one token per
   repository, in one batch, and remembers each. Returns a table token-key →
   token for the ones that came."
  (let ((tokens (make-hash-table :test 'equal))
        (jobs nil))
    (loop for (registry path www-auth) in challenges
          do (let ((key (%token-key registry path)))
               (unless (or (null key) (find key jobs :key #'first :test #'equal))
                 (note-token-realm registry www-auth)
                 (multiple-value-bind (url headers)
                     (ignore-errors (token-request www-auth :auth (registry-auth registry)))
                   (when url
                     (push (list key registry path url
                                 (list :method :get :url url :headers headers
                                       :verify (%verify registry) :force-binary nil))
                           jobs))))))
    (setf jobs (nreverse jobs))
    (loop for (key registry path url) in jobs
          for answer in (and jobs (http-exchange-batch (mapcar #'fifth jobs)))
          do (when (consp answer)
               (multiple-value-bind (token expires-in)
                   (ignore-errors (parse-token-response (first answer) (second answer) url))
                 (when token
                   (remember-token registry path token expires-in)
                   (setf (gethash key tokens) token)))))
    tokens))

(defun %use-token (registry path tokens)
  "Give REGISTRY the token TOKENS has for PATH's repository, as
   HANDLE-AUTH-CHALLENGE does. True when there was one."
  (let ((token (gethash (%token-key registry path) tokens)))
    (when token
      (if (registry-auth registry)
          (setf (auth-config-token (registry-auth registry)) token)
          (setf (registry-auth registry) (make-auth-config :token token)))
      t)))

(defun %send-batch (items indexes)
  (http-exchange-batch
   (mapcar (lambda (i)
             (destructuring-bind (registry method path &key accept timeout) (aref items i)
               (%http-request-plist registry method path accept timeout)))
           indexes)))

(defun registry-request-batch (requests)
  "Send REQUESTS, each (registry method path &key accept timeout), several at
   a time (HTTP-EXCHANGE-BATCH). Returns a list in their order: per request
   the values REGISTRY-REQUEST returns, as a list, or the error it signals.
   Tokens: one request per repository, batched too, made before the requests
   when the registry's token realm is known, else after their 401
   challenges, which are then sent again. A request that got no response
   is sent again through REGISTRY-REQUEST, which retries it. So each result
   is what REGISTRY-REQUEST alone would have given."
  (ensure-http-backend)
  (if (or (not (eq (http-backend-kind) :async))
          (<= (batch-concurrency) 1)
          (null (cdr requests)))
      (mapcar (lambda (r) (apply #'%captured-request r)) requests)
      (let* ((items (coerce requests 'vector))
             (all (loop for i below (length items) collect i)))
        ;; Tokens first, for repositories on a registry whose realm is known.
        (let ((tokens (%fetch-tokens
                       (loop for i in all
                             for (registry method path) = (aref items i)
                             for challenge = (and (member method '(:get :head))
                                                  (null (request-auth-headers registry path))
                                                  (predicted-challenge registry path))
                             when challenge collect (list registry path challenge)))))
          (loop for i in all
                for (registry nil path) = (aref items i)
                do (%use-token registry path tokens)))
        (let* ((results (coerce (%send-batch items all) 'vector))
               (challenged (loop for r across results
                                 for i from 0
                                 when (and (consp r) (eql 401 (second r))
                                           (response-header-value (third r) "www-authenticate"))
                                   collect i)))
          (when challenged
            (let* ((tokens (%fetch-tokens
                            (loop for i in challenged
                                  for (registry nil path) = (aref items i)
                                  collect (list registry path
                                                (response-header-value
                                                 (third (aref results i)) "www-authenticate")))))
                   (again (remove-if-not (lambda (i)
                                           (destructuring-bind (registry method path &rest keys)
                                               (aref items i)
                                             (declare (ignore method keys))
                                             (%use-token registry path tokens)))
                                         challenged)))
              (loop for i in again
                    for answer in (%send-batch items again)
                    do (setf (aref results i) answer))))
          (loop for r across results
                for item across items
                collect (destructuring-bind (registry method path &key accept timeout) item
                          (cond
                            ;; no response: through REGISTRY-REQUEST, with its retries
                            ((and (typep r 'condition)
                                  (or (transport-failure-p r) (typep r 'registry-transport-error)))
                             (%captured-request registry method path :accept accept :timeout timeout))
                            ((typep r 'condition) r)
                            ((<= 200 (second r) 299) r)
                            ;; still challenged (no token came): the one-at-a-time path decides
                            ((eql 401 (second r))
                             (%captured-request registry method path :accept accept :timeout timeout))
                            (t (handler-case
                                   (signal-registry-error (second r) (api-url registry path) (first r))
                                 (error (e) e))))))))))
