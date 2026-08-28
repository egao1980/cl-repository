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
    ;; Keep auto-package-spec provides (slash secondaries included). Drop tests only.
    ;; Slash names are recorded in the annotation; publisher does not mount extra GHCR repos for them.
    (setf (cl-repository-packager/build-matrix:package-spec-provides spec)
          (cl-repository-packager/asdf-plugin:filter-publish-provides
           system (cl-repository-packager/build-matrix:package-spec-provides spec)))
    (setf (cl-repository-packager/build-matrix:package-spec-version spec) version)
    (setf result (cl-repository-packager/build-matrix:build-package spec))
    (format t "~&Publishing ~a/~a:~a~%" namespace system version)
    (cl-repository-packager/publisher:publish-package
     reg namespace version result spec :skip-catalog t)
    ;; Packager 0.16.0 treated skip-catalog as "also skip :latest". The
    ;; package repo is writable by this workflow — write anchors here so
    ;; canned publish works before a newer packager image is pinned.
    (%write-system-name-anchors reg namespace version spec)
    (format t "~&Published ~a/~a:~a~%" namespace system version))
  (%maybe-load-hook "post-publish"))
