;;;; Canned CI phases: install | test | publish.
;;;; Env: CL_REPO_CI_PHASE, optional CL_REPO_SYSTEM / PKG_SYSTEM, CL_REPO_CI_WITH,
;;;;      PKG_VERSION, PACKAGER_VERSION, OCI_NAMESPACE, OCI_REGISTRY,
;;;;      GITHUB_TOKEN, GITHUB_ACTOR, GITHUB_ENV.
;;;;
;;;; Load client FIRST (below), then this file's cl-repo: forms.
;;;; Packager / oci-client package-qualified symbols belong in publish.lisp
;;;; (loaded after %ensure-packager). The reader interned them at LOAD time
;;;; and killed install+test on the first consumer (schema-protocol canary).

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

(defun %registry-form (dirs)
  "ASDF source-registry as a list. A dir//: string lands in
   *source-registry-parameter* and ABCL abcl-contrib type-errors on it.
   :ignore-inherited-configuration skips CL_SOURCE_REGISTRY; deps are OCI."
  `(:source-registry
    ,@(loop for dir in dirs
            when dir
              collect (list :tree (uiop:ensure-directory-pathname dir)))
    :ignore-inherited-configuration))

#+abcl
(defun %abcl-honour-classpath ()
  "ABCL under roswell runs as `java -jar`, so CLASSPATH is ignored by the JVM.
   Add its jars (JNA for CFFI) to ABCL's class loader before the client —
   and thus cffi-abcl — loads. abcl-asdf's maven fallback stopped resolving
   JNA on runner images shipping Maven 3.10 (Class not found: com.sun.jna.Pointer).

   JSS must be loaded first: its ADD-TO-CLASSPATH :after method imports the
   jar's class names into the case-insensitive lookup table that cffi-abcl
   relies on ('com.sun.jna.CallbackReference is read upcased). Without it the
   client's HTTP stack dies with ClassNotFoundException COM.SUN.JNA.CALLBACKREFERENCE."
  (let ((entries (cl-repository-ci-lib:classpath-entries)))
    (when entries
      (handler-case (progn (require :abcl-contrib) (require :jss))
        (error (e) (format t "~&; ci: abcl jss unavailable: ~a~%" e)))
      (let ((jar-import (and (find-package :jss)
                             (find-symbol "JAR-IMPORT" :jss))))
        (dolist (entry entries)
          (format t "~&; ci: abcl add-to-classpath ~a~%" entry)
          (java:add-to-classpath entry)
          ;; Belt and braces: the :after method only exists once jss/classpath
          ;; is loaded, so import explicitly as well (pushnew keeps it idempotent).
          (when (and jar-import (fboundp jar-import)
                     (string-equal (pathname-type entry) "jar"))
            (funcall jar-import entry)))))))

#+abcl (%abcl-honour-classpath)

(defun %load-client ()
  "Load cl-repository-client from the OCI client tree (CL_REPOSITORY_DEST).
   Checkout is added only after the client is loaded, then cleared so the
   next find-system re-reads the system under test."
  (let ((client (cl-repository-ci-lib:nonempty-env "CL_REPOSITORY_DEST")))
    (when client
      (format t "~&; ci: load client from ~a~%" client)
      (asdf:initialize-source-registry (%registry-form (list client))))
    (%ci-muffle (lambda () (asdf:load-system "cl-repository-client")))
    (when client
      (asdf:initialize-source-registry
       (%registry-form (list (uiop:getcwd) client)))
      (cl-repository-ci-lib:clear-checkout-systems))))

(%load-client)

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
  (load (merge-pathnames "publish.lisp" *load-truename*)))

(let ((phase (string-downcase (or (%env "CL_REPO_CI_PHASE") ""))))
  (cond
    ((string= phase "install") (%run-install) (uiop:quit 0))
    ((string= phase "test") (%run-test) (uiop:quit 0))
    ((string= phase "publish") (%run-publish) (uiop:quit 0))
    (t
     (format *error-output* "~&CL_REPO_CI_PHASE must be install, test, or publish (got ~s)~%"
             phase)
     (uiop:quit 1))))
