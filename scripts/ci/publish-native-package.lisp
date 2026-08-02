;;; Publish a cl-repository package with platform native-library overlays
;;; (and optional cffi-grovel-output when grovel/<os>-<arch>/ is present).
;;; Env:
;;;   PKG_NAME PKG_VERSION PKG_DESCRIPTION PKG_LICENSE
;;;   PKG_DEPENDS_ON   — space-separated ASDF system names
;;;   PKG_PROVIDES     — space-separated (default: PKG_NAME)
;;;   PKG_CFFI_LIBS    — space-separated cffi library labels
;;;   PKG_SOURCE_DIR   — Lisp-only source tree
;;;   LIB_ROOT         — directory containing <os>-<arch>/ native dirs
;;;   GROVEL_ROOT      — optional; directory containing <os>-<arch>/ grovel dirs
;;;                      (default: sibling ../grovel of LIB_ROOT)
;;;   PLATFORMS_FILE   — lines "os/arch"
;;;   OCI_REGISTRY REGISTRY_URL OCI_NAMESPACE
;;;   GITHUB_ACTOR GITHUB_TOKEN
;;;   SKIP_CATALOG     — "true" / "false" (default true)

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

(let* ((name (env "PKG_NAME"))
       (version (env "PKG_VERSION")))
  (unless (and name (plusp (length name)))
    (error "PKG_NAME required"))
  (unless (and version (plusp (length version)))
    (error "PKG_VERSION required"))
  (let* ((description (env "PKG_DESCRIPTION" ""))
         (license (env "PKG_LICENSE" "MIT"))
         (depends-on (split-ws (env "PKG_DEPENDS_ON" "")))
         (provides (or (split-ws (env "PKG_PROVIDES" "")) (list name)))
         (cffi-libs (split-ws (env "PKG_CFFI_LIBS" "")))
         (source-dir (uiop:ensure-directory-pathname (env "PKG_SOURCE_DIR")))
         (lib-root (uiop:ensure-directory-pathname (env "LIB_ROOT")))
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
         (platform-lines (uiop:read-file-lines platforms-file))
         (overlays
          (loop for line in platform-lines
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
         (spec (make-instance 'cl-repository-packager/build-matrix:package-spec
                 :name name
                 :version version
                 :source-dir source-dir
                 :license license
                 :description description
                 :depends-on depends-on
                 :provides provides
                 :cffi-libraries cffi-libs
                 :overlays overlays))
         (result (cl-repository-packager/build-matrix:build-package spec)))
    (unless overlays (error "No overlays built from ~a" platforms-file))
    (format t "~%Publishing ~a:~a overlays=~{~a~^,~}~%" name version platform-lines)
    (cl-repository-packager/publisher:publish-package
     reg namespace version result spec :skip-catalog skip-catalog)
    (format t "Published ~a:~a to ~a/~a~%" name version registry-url namespace)))
