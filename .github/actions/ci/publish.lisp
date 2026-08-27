;;;; Loaded by run.lisp AFTER cl-repository-packager + cl-oci-client exist.
;;;;
;;;; Do not package-qualify symbols the pinned packager (0.16.0) does not
;;;; export — LOAD of this file is a READ. Resolve new helpers via find-symbol.

(defun %publish-provides (system provides)
  "Drop test systems; keep slash secondaries. Uses packager filter when present."
  (let ((fn (find-symbol "FILTER-PUBLISH-PROVIDES"
                         "CL-REPOSITORY-PACKAGER/ASDF-PLUGIN")))
    (if (and fn (fboundp fn))
        (funcall fn system provides)
        (let* ((primary (string-downcase (string system)))
               (raw (or provides (list primary)))
               (pred (find-symbol "TEST-SYSTEM-NAME-P"
                                  "CL-REPOSITORY-PACKAGER/ASDF-PLUGIN"))
               (cleaned (remove-if
                         (if (and pred (fboundp pred))
                             pred
                             (lambda (s)
                               (let* ((n (string-downcase (string s)))
                                      (len (length n)))
                                 (or (search "/tests" n)
                                     (search "/test" n)
                                     (and (>= len 5)
                                          (string= n "-test" :start1 (- len 5)))
                                     (and (>= len 6)
                                          (string= n "-tests" :start1 (- len 6)))))))
                         (mapcar (lambda (s) (string-downcase (string s))) raw))))
          (if (member primary cleaned :test #'string=)
              cleaned
              (cons primary cleaned))))))

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
          (%publish-provides
           system (cl-repository-packager/build-matrix:package-spec-provides spec)))
    (setf (cl-repository-packager/build-matrix:package-spec-version spec) version)
    (setf result (cl-repository-packager/build-matrix:build-package spec))
    (format t "~&Publishing ~a/~a:~a~%" namespace system version)
    (cl-repository-packager/publisher:publish-package
     reg namespace version result spec :skip-catalog t)
    (format t "~&Published ~a/~a:~a~%" namespace system version))
  (%maybe-load-hook "post-publish"))
