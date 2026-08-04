;;; Publish a cl-repository package with platform native-library overlays
;;; (and optional cffi-grovel-output when grovel/<os>-<arch>/ is present).
;;;
;;; Packaging metadata comes from the staged .asd via auto-package-spec
;;; (:version :description :license :depends-on + :properties :cl-repo).
;;; Artifact lib/ + grovel/ supply absolute overlay file lists (Lisp source
;;; stays source-only in the tarball).
;;;
;;; Env:
;;;   PKG_NAME         — ASDF system name (required)
;;;   PKG_SOURCE_DIR   — Lisp-only source tree (required)
;;;   LIB_ROOT         — directory containing <os>-<arch>/ native dirs
;;;   GROVEL_ROOT      — optional; sibling ../grovel of LIB_ROOT by default
;;;   PLATFORMS_FILE   — lines "os/arch"
;;;   OCI_REGISTRY REGISTRY_URL OCI_NAMESPACE
;;;   GITHUB_ACTOR GITHUB_TOKEN
;;;   SKIP_CATALOG     — "true" / "false" (default true)
;;; Optional overrides (empty = use .asd):
;;;   PKG_VERSION PKG_DESCRIPTION PKG_LICENSE
;;;   PKG_DEPENDS_ON PKG_PROVIDES PKG_CFFI_LIBS

(require :asdf)
(asdf:initialize-source-registry
 '(:source-registry
   (:tree (:home ".local/share/cl-systems/"))
   :inherit-configuration))
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(ql:quickload :cl-repository-packager :silent t)

(defun env (name &optional default)
  (or (uiop:getenv name) default))

(defun split-ws (s)
  (when (and s (plusp (length s)))
    (loop for start = 0 then (1+ end)
          for end = (position #\Space s :start start)
          for part = (string-trim '(#\Space #\Tab) (subseq s start end))
          unless (string= part "") collect part
          while end)))

(defun absolute-layer-files (dir)
  "Non-recursive files under DIR as (absolute-namestring . file-namestring) pairs."
  (let ((files (uiop:directory-files dir)))
    (unless files
      (error "No files under ~a" dir))
    (loop for abs in files
          collect (cons (namestring abs) (file-namestring abs)))))

(defun default-grovel-root (lib-root)
  "Sibling grovel/ next to lib/ (…/lib → …/grovel)."
  (merge-pathnames
   "grovel/"
   (uiop:pathname-parent-directory-pathname (uiop:ensure-directory-pathname lib-root))))

(defun load-system-asd (name source-dir)
  "Register SOURCE-DIR and load NAME.asd so auto-package-spec can introspect."
  (let* ((source-dir (uiop:ensure-directory-pathname source-dir))
         (asd (merge-pathnames (format nil "~a.asd" name) source-dir)))
    (unless (probe-file asd)
      (error "No ~a (expected ~a.asd under PKG_SOURCE_DIR)" asd name))
    (asdf:initialize-source-registry
     `(:source-registry
       (:directory ,source-dir)
       (:tree (:home ".local/share/cl-systems/"))
       :inherit-configuration))
    (asdf:load-asd asd)
    (asdf:find-system name t)))

(defun build-artifact-overlays (lib-root grovel-root platforms-file)
  (loop for line in (uiop:read-file-lines platforms-file)
        for slash = (position #\/ line)
        when slash
          collect
          (let* ((os (subseq line 0 slash))
                 (arch (subseq line (1+ slash)))
                 (prefix (format nil "~a-~a" os arch))
                 (lib-dir (merge-pathnames (format nil "~a/" prefix) lib-root))
                 (grovel-dir (merge-pathnames (format nil "~a/" prefix) grovel-root))
                 (native-pairs (absolute-layer-files lib-dir))
                 (layers (list (list :role "native-library" :files native-pairs))))
            (when (uiop:directory-exists-p grovel-dir)
              (setf layers
                    (append layers
                            (list (list :role "cffi-grovel-output"
                                        :files (absolute-layer-files grovel-dir))))))
            (make-instance 'cl-repository-packager/build-matrix:overlay-spec
              :os os :arch arch
              :layers layers))))

(defun apply-env-overrides (spec)
  "Optional PKG_* overrides; leave .asd values when env empty."
  (let ((version (env "PKG_VERSION"))
        (description (env "PKG_DESCRIPTION"))
        (license (env "PKG_LICENSE"))
        (depends-on (split-ws (env "PKG_DEPENDS_ON" "")))
        (provides (split-ws (env "PKG_PROVIDES" "")))
        (cffi-libs (split-ws (env "PKG_CFFI_LIBS" ""))))
    (when (and version (plusp (length version)))
      (setf (cl-repository-packager/build-matrix:package-spec-version spec) version))
    (when (and description (plusp (length description)))
      (setf (cl-repository-packager/build-matrix:package-spec-description spec) description))
    (when (and license (plusp (length license)))
      (setf (cl-repository-packager/build-matrix::package-spec-license spec) license))
    (when depends-on
      (setf (cl-repository-packager/build-matrix:package-spec-depends-on spec) depends-on))
    (when provides
      (setf (cl-repository-packager/build-matrix:package-spec-provides spec) provides))
    (when cffi-libs
      (setf (cl-repository-packager/build-matrix::package-spec-cffi-libraries spec) cffi-libs)))
  spec)

(let* ((name (env "PKG_NAME"))
       (source-dir (uiop:ensure-directory-pathname (env "PKG_SOURCE_DIR"))))
  (unless (and name (plusp (length name)))
    (error "PKG_NAME required"))
  (unless (env "PKG_SOURCE_DIR")
    (error "PKG_SOURCE_DIR required"))
  (load-system-asd name source-dir)
  (let* ((lib-root (uiop:ensure-directory-pathname (env "LIB_ROOT")))
         (grovel-root (uiop:ensure-directory-pathname
                       (or (env "GROVEL_ROOT")
                           (namestring (default-grovel-root lib-root)))))
         (platforms-file (env "PLATFORMS_FILE" "/tmp/platforms.txt"))
         (registry-url (env "REGISTRY_URL"))
         (namespace (env "OCI_NAMESPACE"))
         (skip-catalog (string-equal "true" (env "SKIP_CATALOG" "true")))
         (use-auth (string= "ghcr.io" (env "OCI_REGISTRY")))
         (auth (when use-auth
                 (cl-oci-client/auth:make-auth-config
                  :username (env "GITHUB_ACTOR")
                  :password (env "GITHUB_TOKEN"))))
         (reg (if use-auth
                  (cl-oci-client/registry:make-registry registry-url :auth auth)
                  (cl-oci-client/registry:make-registry registry-url)))
         (overlays (build-artifact-overlays lib-root grovel-root platforms-file))
         (spec (apply-env-overrides
                (cl-repository-packager/asdf-plugin:auto-package-spec name))))
    (unless overlays (error "No overlays built from ~a" platforms-file))
    ;; Staging tree is the publish source; asd :cl-repo overlays are relative
    ;; inventory — replace with absolute artifact layers for this build.
    (setf (cl-repository-packager/build-matrix:package-spec-source-dir spec) source-dir)
    (setf (cl-repository-packager/build-matrix:package-spec-overlays spec) overlays)
    (unless (cl-repository-packager/build-matrix:package-spec-version spec)
      (error "Package ~a has no :version in .asd and PKG_VERSION unset" name))
    (let ((result (cl-repository-packager/build-matrix:build-package spec))
          (version (cl-repository-packager/build-matrix:package-spec-version spec)))
      (format t "~%Publishing ~a:~a (auto-package-spec + artifact overlays) overlays=~{~a~^,~}~%"
              name version (uiop:read-file-lines platforms-file))
      (cl-repository-packager/publisher:publish-package
       reg namespace version result spec :skip-catalog skip-catalog)
      (format t "Published ~a:~a to ~a/~a~%" name version registry-url namespace))))
