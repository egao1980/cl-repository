;;;; Loaded by run.lisp AFTER cl-repository-packager + cl-oci-client exist.

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
  (%maybe-load-hook "post-publish"))
