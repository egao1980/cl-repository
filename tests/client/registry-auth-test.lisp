(defpackage :cl-repository-client/tests/registry-auth-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/registry-auth
                #:registry-auth-from-environment #:pull-registry #:registry-host
                #:credential-hosts #:docker-config-credentials #:*docker-config-file*
                #:*default-token-username*)
  (:import-from :cl-oci-client/auth
                #:auth-config-username #:auth-config-password #:auth-config-source)
  (:import-from :cl-oci-client/registry #:registry-auth)
  (:import-from :cl-oci-client/conditions #:auth-error #:not-found-error #:credentials-rejected)
  (:import-from :cl-repository-client/constraint-builder #:list-tags/retry #:*tag-list-attempts*)
  (:import-from :cl-repository-client/project #:absent-package-error-p))
(in-package :cl-repository-client/tests/registry-auth-test)

;;; Pull credentials from the environment (#186): which source wins, which
;;; hosts get them, that nothing prints them, and that a refusal is not read
;;; as an absent package.

(defparameter *variables*
  '("CL_REPO_REGISTRY_TOKEN" "CL_REPO_REGISTRY_USERNAME" "CL_REPO_REGISTRY_HOST"
    "GITHUB_TOKEN" "GITHUB_ACTOR" "DOCKER_CONFIG"))

(defparameter *no-docker-config* #p"/nonexistent/cl-repo-registry-auth-test/config.json")

(defun call-with-env (bindings fn &key (docker *no-docker-config*))
  "Call FN with every credential variable unset (empty) but BINDINGS,
   ((name . value) ...), and DOCKER as Docker's config.json. Restores them."
  (let ((old (mapcar (lambda (v) (cons v (uiop:getenv v))) *variables*)))
    (unwind-protect
         (progn
           (dolist (v *variables*) (setf (uiop:getenv v) ""))
           (loop for (k . v) in bindings do (setf (uiop:getenv k) v))
           (let ((*docker-config-file* docker))
             (funcall fn)))
      (loop for (k . v) in old do (setf (uiop:getenv k) (or v ""))))))

(defmacro with-env ((&rest bindings) &body body)
  "BINDINGS: (name value) ... and an optional (:docker pathname)."
  (let ((docker (find :docker bindings :key #'first))
        (vars (remove :docker bindings :key #'first)))
    `(call-with-env (list ,@(mapcar (lambda (b) `(cons ,(first b) ,(second b))) vars))
                    (lambda () ,@body)
                    ,@(when docker `(:docker ,(second docker))))))

(defun write-docker-config (json)
  "A fresh temporary file holding JSON."
  (let ((path (merge-pathnames (format nil "cl-repo-docker-~36r.json"
                                       (random (expt 36 10) (make-random-state t)))
                               (uiop:temporary-directory))))
    (with-open-file (s path :direction :output :if-exists :supersede)
      (write-string json s))
    path))

(defun docker-auth (user password)
  (cl-base64:string-to-base64-string (format nil "~a:~a" user password)))

(defmacro with-docker-config ((var json) &body body)
  `(let ((,var (write-docker-config ,json)))
     (unwind-protect (progn ,@body)
       (uiop:delete-file-if-exists ,var))))

(defun source-of (url)
  (let ((auth (registry-auth-from-environment url)))
    (and auth (auth-config-source auth))))

(deftest nothing-set-pulls-anonymously
  (with-env ()
    (ok (null (registry-auth-from-environment "https://ghcr.io")))
    (ok (null (registry-auth (pull-registry "https://ghcr.io"))))
    (ok (null (registry-auth (pull-registry "http://localhost:5050"))))))

(deftest empty-variables-count-as-unset
  "Actions passes a secret that is not defined as an empty string."
  (with-env (("CL_REPO_REGISTRY_TOKEN" "") ("GITHUB_TOKEN" "") ("GITHUB_ACTOR" "someone"))
    (ok (null (registry-auth-from-environment "https://ghcr.io")))))

(deftest cl-repo-registry-token-comes-first
  (with-docker-config (file (format nil "{\"auths\":{\"ghcr.io\":{\"auth\":\"~a\"}}}"
                                    (docker-auth "docker-user" "docker-pw")))
    (with-env (("CL_REPO_REGISTRY_TOKEN" "tok-explicit") ("CL_REPO_REGISTRY_USERNAME" "me")
               ("GITHUB_TOKEN" "tok-actions") ("GITHUB_ACTOR" "actor")
               (:docker file))
      (let ((auth (registry-auth-from-environment "https://ghcr.io")))
        (ok (equal "CL_REPO_REGISTRY_TOKEN" (auth-config-source auth)))
        (ok (equal "me" (auth-config-username auth)))
        (ok (equal "tok-explicit" (auth-config-password auth)))))
    (with-env (("GITHUB_TOKEN" "tok-actions") ("GITHUB_ACTOR" "actor") (:docker file))
      (let ((auth (registry-auth-from-environment "https://ghcr.io")))
        (ok (equal "GITHUB_TOKEN" (auth-config-source auth)) "then GITHUB_TOKEN")
        (ok (equal "actor" (auth-config-username auth)))
        (ok (equal "tok-actions" (auth-config-password auth)))))
    (with-env ((:docker file))
      (let ((auth (registry-auth-from-environment "https://ghcr.io")))
        (ok (equal (uiop:native-namestring (truename file)) (auth-config-source auth))
            "then Docker's config.json")
        (ok (equal "docker-user" (auth-config-username auth)))
        (ok (equal "docker-pw" (auth-config-password auth)))))))

(deftest the-token-user-name-defaults
  (with-env (("CL_REPO_REGISTRY_TOKEN" "tok"))
    (ok (equal *default-token-username*
               (auth-config-username (registry-auth-from-environment "https://ghcr.io"))))))

(deftest github-token-needs-github-actor
  (with-env (("GITHUB_TOKEN" "tok-actions"))
    (ok (null (registry-auth-from-environment "https://ghcr.io")))))

(deftest github-token-goes-to-ghcr-only
  (with-env (("GITHUB_TOKEN" "tok-actions") ("GITHUB_ACTOR" "actor"))
    (ok (equal "GITHUB_TOKEN" (source-of "https://ghcr.io")))
    (ok (equal "GITHUB_TOKEN" (source-of "ghcr.io")))
    (ok (equal "GITHUB_TOKEN" (source-of "https://GHCR.io/")))
    (ok (null (source-of "https://registry.example.com")))
    (ok (null (source-of "http://localhost:5050")))
    (ok (null (source-of "https://ghcr.io.example.com")))
    (ok (null (registry-auth (pull-registry "https://registry.example.com"))))))

(deftest cl-repo-registry-token-goes-to-its-hosts
  (with-env (("CL_REPO_REGISTRY_TOKEN" "tok"))
    (ok (equal '("ghcr.io") (credential-hosts)) "ghcr.io by default")
    (ok (equal "CL_REPO_REGISTRY_TOKEN" (source-of "https://ghcr.io")))
    (ok (null (source-of "https://registry.example.com"))))
  (with-env (("CL_REPO_REGISTRY_TOKEN" "tok")
             ("CL_REPO_REGISTRY_HOST" "https://Registry.example.com, localhost:5050"))
    (ok (equal '("registry.example.com" "localhost:5050") (credential-hosts)))
    (ok (equal "CL_REPO_REGISTRY_TOKEN" (source-of "https://registry.example.com")))
    (ok (equal "CL_REPO_REGISTRY_TOKEN" (source-of "http://localhost:5050")))
    (ok (null (source-of "https://ghcr.io")) "not ghcr.io once the hosts are named"))
  (with-env (("CL_REPO_REGISTRY_TOKEN" "tok") ("CL_REPO_REGISTRY_HOST" "registry.example.com")
             ("GITHUB_TOKEN" "tok-actions") ("GITHUB_ACTOR" "actor"))
    (ok (equal "GITHUB_TOKEN" (source-of "https://ghcr.io"))
        "a host the explicit token is not for falls to the next source")))

(deftest docker-config-entries
  (with-docker-config (file (format nil "{\"auths\":{\"https://registry.example.com/v1/\":{\"auth\":\"~a\"},
                                       \"other.example.com\":{\"username\":\"u2\",\"password\":\"p2\"},
                                       \"ghcr.io\":{}},
                                       \"credsStore\":\"desktop\"}"
                                    (docker-auth "u1" "p:1")))
    (multiple-value-bind (user password) (docker-config-credentials "registry.example.com" file)
      (ok (equal "u1" user) "a URL key matches its host")
      (ok (equal "p:1" password) "the password may hold a colon"))
    (multiple-value-bind (user password) (docker-config-credentials "other.example.com" file)
      (ok (equal "u2" user))
      (ok (equal "p2" password)))
    (ok (null (docker-config-credentials "ghcr.io" file)) "a credential-helper entry gives nothing")
    (ok (null (docker-config-credentials "elsewhere.example.com" file)))
    (with-env ((:docker file))
      (ok (null (source-of "https://ghcr.io")))
      (ok (source-of "https://other.example.com") "each host gets its own entry")))
  (with-docker-config (file "{not json")
    (ok (null (docker-config-credentials "ghcr.io" file)) "a file that does not parse gives nothing"))
  (ok (null (docker-config-credentials "ghcr.io" *no-docker-config*)) "no file, nothing"))

(deftest each-registry-gets-its-own-auth-config
  "A registry stores its bearer token in its AUTH-CONFIG: two registries
   must not share one."
  (with-env (("GITHUB_TOKEN" "tok-actions") ("GITHUB_ACTOR" "actor"))
    (ok (not (eq (registry-auth (pull-registry "https://ghcr.io"))
                 (registry-auth (pull-registry "https://ghcr.io")))))))

(deftest registry-hosts
  (ok (equal "ghcr.io" (registry-host "https://ghcr.io")))
  (ok (equal "ghcr.io" (registry-host "ghcr.io")))
  (ok (equal "ghcr.io" (registry-host "https://GHCR.IO/v2/")))
  (ok (equal "localhost:5050" (registry-host "http://localhost:5050"))))

(deftest nothing-prints-the-token
  (with-env (("CL_REPO_REGISTRY_TOKEN" "tok-do-not-print"))
    (let ((auth (registry-auth-from-environment "https://ghcr.io")))
      (ng (search "tok-do-not-print" (prin1-to-string auth)))
      (ng (search "tok-do-not-print" (princ-to-string auth)))
      (ng (search "tok-do-not-print" (prin1-to-string (pull-registry "https://ghcr.io"))))))
  (let ((report (princ-to-string (make-condition 'credentials-rejected
                                                 :status 403 :url "https://ghcr.io/token?service=ghcr.io"
                                                 :body "{\"errors\":[{\"code\":\"DENIED\",\"message\":\"denied\"}]}"
                                                 :source "CL_REPO_REGISTRY_TOKEN" :username "me"))))
    (ok (search "CL_REPO_REGISTRY_TOKEN" report) "the report names the variable")
    (ok (search "DENIED: denied" report))
    (ok (search "does not fall back" report))))

;;; A refusal is not an absent package

(defun quietly (fn)
  (let ((cl-oci/runtime:*quiet* nil))
    (with-output-to-string (*standard-output*)
      (funcall fn))))

(deftest list-tags-retry-propagates-refused-credentials
  (let ((calls 0)
        (*tag-list-attempts* 3))
    (with-env (("GITHUB_TOKEN" "tok-actions") ("GITHUB_ACTOR" "actor"))
      (ok (signals (quietly
                    (lambda ()
                      (list-tags/retry (pull-registry "https://ghcr.io") "ns/x"
                                       :lister (lambda (r p)
                                                 (declare (ignore r p))
                                                 (incf calls)
                                                 (error 'credentials-rejected :status 403
                                                                              :source "GITHUB_TOKEN")))))
                   'credentials-rejected)))
    (ok (= 1 calls) "not retried, not NIL")))

(deftest a-refusal-with-credentials-names-them
  "Good credentials refused for one repository read as absent, as before,
   and the log says which credentials could not read it."
  (with-env (("GITHUB_TOKEN" "tok-actions") ("GITHUB_ACTOR" "actor"))
    (let* ((result :unset)
           (log (quietly
                 (lambda ()
                   (setf result
                         (list-tags/retry (pull-registry "https://ghcr.io") "ns/x"
                                          :lister (lambda (r p)
                                                    (declare (ignore r p))
                                                    (error 'auth-error :status 403))))))))
      (ok (null result))
      (ok (search "package not found in registry" log))
      (ok (search "GITHUB_TOKEN cannot read it" log))
      (ng (search "tok-actions" log)))))

(deftest absent-packages
  (ok (absent-package-error-p (make-condition 'not-found-error :status 404)))
  (ok (absent-package-error-p (make-condition 'auth-error :status 403)))
  (ng (absent-package-error-p (make-condition 'credentials-rejected :status 403
                                                                    :source "GITHUB_TOKEN"))))
