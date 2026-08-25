;;;; Canned CI phases: install | test | publish.
;;;; Env: CL_REPO_CI_PHASE, optional CL_REPO_SYSTEM / PKG_SYSTEM, CL_REPO_CI_WITH,
;;;;      PKG_VERSION, PACKAGER_VERSION, OCI_NAMESPACE, OCI_REGISTRY,
;;;;      GITHUB_TOKEN, GITHUB_ACTOR, GITHUB_ENV.
;;;;
;;;; Load client FIRST, then this file's cl-repo: forms.

(setf *debugger-hook*
      (lambda (c h)
        (declare (ignore h))
        (format *error-output* "~&UNHANDLED: ~A~%" c)
        (uiop:quit 1)))

#+sbcl (sb-ext:disable-debugger)

(setf asdf:*compile-file-failure-behaviour* :warn)

(load (merge-pathnames "ci-lib.lisp" *load-truename*))

(defun %ci-muffle (fn)
  #+sbcl
  (handler-bind ((sb-ext:defconstant-uneql
                  (lambda (c)
                    (let ((r (find-restart 'continue c)))
                      (when r (invoke-restart r))))))
    (funcall fn))
  #-sbcl
  (funcall fn))

(%ci-muffle (lambda () (asdf:load-system "cl-repository-client")))

(defun %env (name &optional default)
  (or (cl-repository-ci-lib:nonempty-env name) default))

(defun %maybe-load-hook (phase)
  (let ((path (cl-repository-ci-lib:hook-file phase)))
    (when (probe-file path)
      (format t "~&; ci: hook ~a~%" path)
      (load path))))

(defun %resolve-system ()
  (or (%env "CL_REPO_SYSTEM")
      (%env "PKG_SYSTEM")
      (cl-repository-ci-lib:discover-primary-system (uiop:getcwd))))

(defun %add-default-registry ()
  (let ((url (%env "CL_REPO_REGISTRY" "https://ghcr.io"))
        (ns (%env "CL_REPO_NAMESPACE" "egao1980/cl-systems")))
    (cl-repo:add-registry url :namespace ns :priority :prepend)))

(defun %record-versions (pairs)
  (let ((env-file (uiop:getenv "GITHUB_ENV")))
    (dolist (pair pairs)
      (let ((ver (cl-repo:installed-system-version (car pair))))
        (when ver
          (format t "~&; ci: ~a=~a~%" (cdr pair) ver)
          (when env-file
            (with-open-file (out env-file :direction :output
                                 :if-exists :append :if-does-not-exist :create)
              (format out "~a=~a~%" (cdr pair) ver))))))))

(defun %run-install ()
  (let* ((system (%resolve-system))
         (ci nil)
         (extra (cl-repository-ci-lib:split-ws (%env "CL_REPO_CI_WITH"))))
    (format t "~&; ci: install ~a~%" system)
    (%add-default-registry)
    (%maybe-load-hook "pre-install")
    (setf ci (cl-repository-ci-lib:system-ci-plist system))
    (%ci-muffle
     (lambda ()
       (apply #'cl-repo:ensure-system-dependencies system
              :also-tests (cl-repository-ci-lib:ci-also-tests ci)
              (append (let ((with (cl-repository-ci-lib:ci-with ci extra)))
                        (when with (list :with with)))
                      (let ((sources (cl-repository-ci-lib:ci-sources ci)))
                        (when sources (list :sources sources)))))))
    (%record-versions (cl-repository-ci-lib:ci-record-versions ci))
    (%maybe-load-hook "post-install")
    (format t "~&; ci: install phase done~%")))

(defun %run-test ()
  (let* ((system (%resolve-system))
         (ci (cl-repository-ci-lib:system-ci-plist system)))
    (format t "~&; ci: test ~a~%" system)
    (cl-repository-client/asdf-integration:configure-asdf-source-registry)
    (cl-repository-client/asdf-integration:load-system-init-files)
    (%maybe-load-hook "pre-test")
    (%ci-muffle
     (lambda ()
       (dolist (n (cl-repository-ci-lib:ci-load-before-test ci))
         (format t "~&; ci: load-before-test ~a~%" n)
         (asdf:load-system n))
       (asdf:load-system system)
       (asdf:test-system system)))
    (%maybe-load-hook "post-test")
    (format t "~&; ci: tests ok~%")))

(defun %hide-bootstrap (source-dir)
  "Move .cl-repository out of SOURCE-DIR so packager 0.16.0 does not ship it."
  (let* ((root (uiop:ensure-directory-pathname source-dir))
         (bootstrap (merge-pathnames ".cl-repository/" root)))
    (when (uiop:directory-exists-p bootstrap)
      (let* ((stash-parent (uiop:ensure-directory-pathname
                            (or (uiop:getenv "RUNNER_TEMP")
                                (namestring (uiop:temporary-directory)))))
             (dest (merge-pathnames "cl-repository-bootstrap/" stash-parent)))
        (when (uiop:directory-exists-p dest)
          (uiop:delete-directory-tree dest :validate t :if-does-not-exist :ignore))
        (ensure-directories-exist stash-parent)
        (uiop:run-program (list "mv" (namestring bootstrap) (namestring dest))
                          :output t :error-output t)
        (format t "~&; ci: hid .cl-repository -> ~a~%" dest)))))

(defun %ensure-packager ()
  (cl-repo:add-registry "https://ghcr.io" :namespace "egao1980/cl-repository" :priority :prepend)
  (cl-repo:add-registry "https://ghcr.io" :namespace "egao1980/cl-systems" :priority :append)
  (let ((ver (%env "PACKAGER_VERSION")))
    (%ci-muffle
     (lambda ()
       (if ver
           (cl-repo:ensure-systems "cl-repository-packager" :version ver :default-source :oci)
           (cl-repo:ensure-systems "cl-repository-packager" :default-source :oci))
       (cl-repo:ensure-systems "cl-oci-client" :default-source :oci))))
  (cl-repository-client/asdf-integration:configure-asdf-source-registry)
  (cl-repository-client/asdf-integration:load-system-init-files)
  (%ci-muffle
   (lambda ()
     (asdf:load-system "cl-repository-packager")
     (asdf:load-system "cl-oci-client"))))

(defun %run-publish ()
  (%ensure-packager)
  (let* ((system (%resolve-system))
         (version (or (%env "PKG_VERSION")
                      (asdf:component-version (asdf:find-system system))))
         (registry-url (%env "OCI_REGISTRY" "ghcr.io"))
         (namespace (string-downcase (%env "OCI_NAMESPACE" "egao1980/cl-systems")))
         (auth (cl-oci-client/auth:make-auth-config
                :username (%env "GITHUB_ACTOR" "x-access-token")
                :password (or (%env "GITHUB_TOKEN")
                              (error "GITHUB_TOKEN required"))))
         (reg (cl-oci-client/registry:make-registry
               (format nil "https://~a" registry-url) :auth auth)))
    (format t "~&; ci: publish ~a:~a~%" system version)
    (%maybe-load-hook "pre-publish")
    (%hide-bootstrap (asdf:system-source-directory system))
    (let ((spec (cl-repository-packager/asdf-plugin:auto-package-spec system))
          (result nil))
      ;; One GHCR package per owning repo — never auto-publish *-test secondaries.
      (setf (cl-repository-packager/build-matrix:package-spec-provides spec)
            (list system))
      (setf (cl-repository-packager/build-matrix:package-spec-version spec) version)
      (setf result (cl-repository-packager/build-matrix:build-package spec))
      (format t "~&Publishing ~a/~a:~a~%" namespace system version)
      (cl-repository-packager/publisher:publish-package
       reg namespace version result spec :skip-catalog t)
      (format t "~&Published ~a/~a:~a~%" namespace system version))
    (%maybe-load-hook "post-publish")))

(let ((phase (string-downcase (or (%env "CL_REPO_CI_PHASE") ""))))
  (cond
    ((string= phase "install") (%run-install) (uiop:quit 0))
    ((string= phase "test") (%run-test) (uiop:quit 0))
    ((string= phase "publish") (%run-publish) (uiop:quit 0))
    (t
     (format *error-output* "~&CL_REPO_CI_PHASE must be install, test, or publish (got ~s)~%"
             phase)
     (uiop:quit 1))))
