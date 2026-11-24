(defpackage :cl-repository-client/registry-auth
  (:use :cl)
  (:import-from :cl-oci-client/auth #:make-auth-config)
  (:import-from :cl-oci-client/registry #:make-registry)
  (:import-from :babel #:octets-to-string)
  (:import-from :cl-base64 #:base64-string-to-usb8-array)
  (:import-from :yason)
  (:export #:registry-auth-from-environment
           #:pull-registry
           #:registry-host
           #:credential-hosts
           #:docker-config-credentials
           #:*docker-config-file*
           #:*default-token-username*))
(in-package :cl-repository-client/registry-auth)

;;; Pull credentials (#186). A registry the client builds for a pull takes
;;; credentials from the environment, so private packages install; with none
;;; set it pulls anonymously, as before. The first source that applies wins:
;;;
;;;  1. CL_REPO_REGISTRY_TOKEN, user CL_REPO_REGISTRY_USERNAME (default
;;;     x-access-token), for the hosts in CL_REPO_REGISTRY_HOST (comma
;;;     separated; default ghcr.io).
;;;  2. GITHUB_TOKEN, user GITHUB_ACTOR (what GitHub Actions sets), for
;;;     ghcr.io only. Both must be set.
;;;  3. The host's entry in the "auths" of Docker's config.json
;;;     ($DOCKER_CONFIG/config.json, else ~/.docker/config.json), as
;;;     `docker login` writes it: "auth" (base64 user:password) or
;;;     "username" + "password". Credential helpers (credsStore,
;;;     credHelpers) and identity tokens are not read.
;;;
;;; Empty variables count as unset (Actions passes a missing secret as "").
;;; Credentials go only to their hosts, and nothing prints a secret: an
;;; AUTH-CONFIG prints redacted, and CREDENTIALS-REJECTED names the source,
;;; never the value. Publishing (the packager) does not use these: a pull
;;; never turns into a push with them.

(defparameter *default-token-username* "x-access-token"
  "User name sent with CL_REPO_REGISTRY_TOKEN when CL_REPO_REGISTRY_USERNAME
   is unset. ghcr.io accepts any user name with a token.")

(defparameter *github-registry-host* "ghcr.io"
  "The one host GITHUB_TOKEN is sent to.")

(defvar *docker-config-file* nil
  "Docker's config.json. NIL: $DOCKER_CONFIG/config.json, else
   ~/.docker/config.json.")

(defun %env (name)
  "NAME's value, or NIL when it is unset or empty."
  (let ((v (uiop:getenv name)))
    (and v (plusp (length v)) v)))

(defun registry-host (url)
  "The host[:port] of a registry URL or host name, lowercased:
   \"https://GHCR.io/\" and \"ghcr.io\" are both \"ghcr.io\"."
  (let* ((scheme (search "://" url))
         (start (if scheme (+ scheme 3) 0))
         (end (or (position #\/ url :start start) (length url))))
    (string-downcase (subseq url start end))))

(defun credential-hosts ()
  "The hosts CL_REPO_REGISTRY_TOKEN is sent to: CL_REPO_REGISTRY_HOST, comma
   or space separated, else ghcr.io."
  (let ((v (%env "CL_REPO_REGISTRY_HOST")))
    (if v
        (mapcar #'registry-host
                (remove "" (uiop:split-string v :separator '(#\, #\Space #\Tab))
                        :test #'string=))
        (list *github-registry-host*))))

(defun docker-config-file ()
  (or *docker-config-file*
      (let ((dir (%env "DOCKER_CONFIG")))
        (if dir
            (merge-pathnames "config.json" (uiop:ensure-directory-pathname dir))
            (merge-pathnames ".docker/config.json" (user-homedir-pathname))))))

(defvar *docker-config-cache* nil
  "(namestring write-date auths) of the Docker config last read: the client
   builds a registry per lookup, and reads the file once.")

(defun %docker-auths (file)
  "The \"auths\" table of Docker config FILE, or NIL when there is no such
   file. A file that does not parse as JSON is ignored, as it gives no
   credentials."
  (let* ((path (probe-file file))
         (date (and path (file-write-date path)))
         (key (and path (namestring path)))
         (cached *docker-config-cache*))
    (cond
      ((null path) nil)
      ((and cached (equal key (first cached)) (eql date (second cached)))
       (third cached))
      (t
       (let* ((json (handler-case (yason:parse (uiop:read-file-string path))
                      (error () nil)))
              (auths (and (hash-table-p json) (gethash "auths" json))))
         (unless (hash-table-p auths) (setf auths nil))
         (setf *docker-config-cache* (list key date auths))
         auths)))))

(defun %decode-docker-auth (auth)
  "(values username password) of a config.json \"auth\": base64 of
   user:password."
  (let* ((text (handler-case (octets-to-string (base64-string-to-usb8-array auth)
                                               :encoding :utf-8)
                 (error () nil)))
         (colon (and text (position #\: text))))
    (when (and colon (plusp colon))
      (values (subseq text 0 colon) (subseq text (1+ colon))))))

(defun docker-config-credentials (host &optional (file (docker-config-file)))
  "(values username password file) for HOST from the \"auths\" of Docker
   config FILE, or NIL. An entry's key may be a host or a URL
   (\"https://ghcr.io\")."
  (let ((auths (%docker-auths file))
        (host (registry-host host)))
    (when auths
      (loop for key being the hash-keys of auths using (hash-value entry)
            when (and (hash-table-p entry) (string= host (registry-host key)))
              do (let ((auth (gethash "auth" entry))
                       (username (gethash "username" entry))
                       (password (gethash "password" entry)))
                   (multiple-value-bind (u p)
                       (cond ((and (stringp auth) (plusp (length auth)))
                              (%decode-docker-auth auth))
                             ((and (stringp username) (stringp password)
                                   (plusp (length password)))
                              (values username password)))
                     (when u
                       (return (values u p (probe-file file))))))))))

(defun registry-auth-from-environment (registry-url)
  "Credentials for pulls from REGISTRY-URL, as a fresh AUTH-CONFIG (the
   registry keeps its bearer token in it), or NIL to pull anonymously. The
   sources, in order, are in the comment above; the first that applies to
   REGISTRY-URL's host wins."
  (let ((host (registry-host registry-url)))
    (or (let ((token (%env "CL_REPO_REGISTRY_TOKEN")))
          (and token
               (member host (credential-hosts) :test #'string=)
               (make-auth-config :username (or (%env "CL_REPO_REGISTRY_USERNAME")
                                               *default-token-username*)
                                 :password token
                                 :source "CL_REPO_REGISTRY_TOKEN")))
        (let ((token (%env "GITHUB_TOKEN"))
              (actor (%env "GITHUB_ACTOR")))
          (and token actor
               (string= host *github-registry-host*)
               (make-auth-config :username actor :password token :source "GITHUB_TOKEN")))
        (multiple-value-bind (username password file) (docker-config-credentials host)
          (and username
               (make-auth-config :username username :password password
                                 :source (uiop:native-namestring file)))))))

(defun pull-registry (url)
  "A REGISTRY for pulls from URL, with the credentials
   REGISTRY-AUTH-FROM-ENVIRONMENT finds for it (none: anonymous)."
  (make-registry url :auth (registry-auth-from-environment url)))
