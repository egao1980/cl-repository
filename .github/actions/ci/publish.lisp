;;;; Loaded by run.lisp AFTER cl-repository-packager + cl-oci-client exist.

(defun %write-system-name-anchors (reg namespace version spec)
  "Write <ns>/<system>:latest on the package repo. Packager 0.16.0 skipped
   this when :skip-catalog t; keep a compat write until a newer packager is pinned."
  (let* ((provides (or (cl-repository-packager/build-matrix:package-spec-provides spec)
                       (list (cl-repository-packager/build-matrix:package-spec-name spec))))
         (canonical (first provides)))
    (dolist (system-name provides)
      (unless (cl-oci/system-names:slash-system-name-p system-name)
        (let ((sys-repo (format nil "~a/~a" namespace
                                (cl-oci/system-names:oci-package-name system-name))))
          (handler-case
              (let ((digest (cl-repository-packager/publisher::ensure-system-name-anchor
                             reg sys-repo system-name canonical version)))
                (cl-repository-packager/publisher::push-provider-referrer
                 reg sys-repo digest spec version)
                (format t "~&  Wrote ~a:latest~%" sys-repo))
            (error (e)
              (format t "~&  Warning: system-name anchor ~a failed: ~A~%" sys-repo e))))))))

(defun %stash-sibling-asds (files)
  "Move FILES out of the checkout for the build. → ((stashed . original) …)."
  (when files
    (let ((dir (uiop:ensure-directory-pathname
                (merge-pathnames "cl-repo-sibling-asds/"
                                 (uiop:ensure-directory-pathname
                                  (or (uiop:getenv "RUNNER_TEMP")
                                      (namestring (uiop:temporary-directory))))))))
      (ensure-directories-exist dir)
      (loop for file in files
            for dest = (merge-pathnames (file-namestring file) dir)
            do (when (probe-file dest) (delete-file dest))
               (rename-file file dest)
               (format t "~&; ci: not packaging sibling ~a (a package of its own)~%"
                       (file-namestring file))
            collect (cons dest file)))))

(defun %restore-sibling-asds (stashed)
  (loop for (dest . file) in stashed
        do (rename-file dest file)))

(defun %checkout-system (system)
  "SYSTEM as defined by the checkout. An installed copy that provides the same
   name (a provides symlink) must never be what gets packaged."
  (let* ((checkout (uiop:ensure-directory-pathname (uiop:getcwd)))
         (found (asdf:find-system system))
         (dir (asdf:system-source-directory found)))
    (unless (and dir (uiop:pathname-equal (truename dir) (truename checkout)))
      (error "Refusing to publish ~a from ~a: that is not the checkout ~a. ~
              An installed package shadows the system under test."
             system dir checkout))
    found))

(let* ((system (%resolve-system))
       (declared (asdf:component-version (%checkout-system system)))
       (version (cl-repository-ci-lib:check-publish-version
                 system (%env "PKG_VERSION") declared))
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
    ;; Keep auto-package-spec provides (slash secondaries included). Drop tests only.
    ;; Slash names are recorded in the annotation; publisher does not mount extra GHCR repos for them.
    ;; The published system first (the publisher pushes to the first name's
    ;; repo); siblings whose .asd declares another :version are not mounted.
    ;; An explicit system input from a multi-.asd checkout publishes that
    ;; system alone (plus slash secondaries) unless its .asd sets :provides.
    (multiple-value-bind (own siblings)
        (cl-repository-ci-lib:own-provides
         system
         (cl-repository-packager/asdf-plugin:filter-publish-provides
          system (cl-repository-packager/build-matrix:package-spec-provides spec))
         :explicit-system (or (%env "CL_REPO_SYSTEM") (%env "PKG_SYSTEM"))
         :declared-provides (getf (cl-repository-ci-lib:system-cl-repo-properties
                                   (asdf:find-system system))
                                  :provides)
         :source-dir (uiop:getcwd))
      (dolist (name siblings)
        (format t "~&; ci: not mounting sibling ~a (its own .asd; set :cl-repo :provides to mount it)~%"
                name))
      (multiple-value-bind (kept dropped)
          (cl-repository-ci-lib:publish-provides
           system version own
           (cl-repository-ci-lib:discover-asd-system-versions (uiop:getcwd)))
        (dolist (name dropped)
          (format t "~&; ci: not mounting ~a at ~a (its .asd has another :version)~%"
                  name version))
        (setf (cl-repository-packager/build-matrix:package-spec-provides spec) kept)))
    (setf (cl-repository-packager/build-matrix:package-spec-version spec) version)
    ;; Sibling .asd files (systems this package does not provide) stay out of
    ;; the layer: a stale copy shadows the sibling's own package (#117).
    (let ((stashed (%stash-sibling-asds
                    (cl-repository-ci-lib:sibling-asd-files
                     (uiop:getcwd)
                     (cl-repository-packager/build-matrix:package-spec-provides spec)))))
      (unwind-protect
           (setf result (cl-repository-packager/build-matrix:build-package spec))
        (%restore-sibling-asds stashed)))
    (format t "~&Publishing ~a/~a:~a~%" namespace system version)
    (cl-repository-packager/publisher:publish-package
     reg namespace version result spec :skip-catalog t)
    ;; Packager 0.16.0 treated skip-catalog as "also skip :latest". The
    ;; package repo is writable by this workflow — write anchors here so
    ;; canned publish works before a newer packager image is pinned.
    (%write-system-name-anchors reg namespace version spec)
    (format t "~&Published ~a/~a:~a~%" namespace system version))
  (%maybe-load-hook "post-publish"))
