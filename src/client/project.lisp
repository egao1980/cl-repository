(defpackage :cl-repository-client/project
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:msg)
  (:import-from :cl-repository-client/commands
                #:cmd-install #:cmd-restore
                #:*default-registry* #:*default-namespace*)
  (:import-from :cl-repository-client/quickload
                #:add-registry #:ensure-system-dependencies #:ensure-systems)
  (:import-from :cl-repository-client/asd-rewrite #:asd-defsystem-depends-on)
  (:import-from :cl-oci-client/conditions #:registry-error #:not-found-error #:auth-error)
  (:import-from :cl-oci-client/pin #:with-loaded-systems-pinned #:pinned-system-p #:unpin-system)
  (:import-from :cl-repository-client/dep-satisfy #:system-satisfied-p #:asdf-dep-spec #:note-minimum)
  (:import-from :cl-repository-client/version-utils #:version< #:select-preferred-version)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-path #:read-lockfile #:lockfile-entry-system #:lockfile-entry-version)
  (:import-from :cl-repository-client/asdf-integration
                #:configure-asdf-source-registry)
  (:import-from :cl-repository-client/installer #:systems-root #:*requested-overlay*
                #:system-install-path #:extract-layer)
  (:import-from :cl-repository-client/qlot-integration
                #:read-qlfile #:read-qlfile-lock
                #:qlot-entry-kind #:qlot-entry-name #:qlot-entry-ref #:qlot-entry-snapshot)
  (:import-from :cl-repository-client/platform-resolver
                #:choose-overlay-plists #:detect-local-platform #:overlay-key)
  (:import-from :cl-repository-client/asd-rewrite #:read-system-overlays)
  (:export #:client-source-tree
           #:*sync-with*
           #:ensure-default-registry
           #:register-project
           #:project-registry-directories
           #:explicit-source-registry-entries
           #:source-registry-form
           #:discover-project-system
           #:ensure-defsystem-depends-on
           #:expand-ci-env
           #:cmd-sync
           #:client-runs-older-system
           #:older-system-name
           #:older-system-loaded-version
           #:older-system-required-version
           #:*reload-unsafe-systems*
           #:reload-safe-system-p
           #:ensure-project-requirements
           #:cmd-test
           #:prepare-test
           #:*test-in-subprocess*
           #:tests-failed
           #:cmd-run
           #:cmd-grovel
           #:*default-ql-dist*
           #:lisp-command-p
           #:split-lisp-command-args
           #:expand-lisp-command))
(in-package :cl-repository-client/project)

(defvar *default-ql-dist* "https://beta.quicklisp.org/dist/quicklisp.txt"
  "Dist used for qlfile ql entries until a dist line says otherwise.")

(defvar *sync-stack* nil)

(defun client-source-tree ()
  "Directory that contains the client the running image loaded, or the install tree."
  (or (uiop:getenv-absolute-directory "CL_REPOSITORY_CLIENT_DIR")
      (let ((sys (asdf:find-system "cl-repository-client" nil)))
        (when sys
          (let ((dir (asdf:system-source-directory sys)))
            (when (and dir (probe-file (merge-pathnames "cl-repository-client.asd" dir)))
              dir))))
      (uiop:getenv-absolute-directory "CL_REPOSITORY_DEST")
      (error "cl-repo: cannot find the cl-repository client tree")))

(defun ensure-default-registry ()
  (add-registry *default-registry* :namespace *default-namespace* :priority :append))

(defun explicit-source-registry-entries (&optional (env (uiop:getenv "CL_SOURCE_REGISTRY")))
  "The (:tree DIR) and (:directory DIR) entries the user passed in ENV
   (CL_SOURCE_REGISTRY, either syntax), with absolute DIRs. Directives are
   dropped: :inherit-configuration would bring in the user's
   source-registry.conf.d (workspace checkouts), which the sync's satisfied
   check then counted although nothing told the test image about them
   (cl-repository#99). The project registry carries these entries, so the
   sync, the fresh test image and `cl-repo run` all see the same trees."
  (when (and env (plusp (length (string-trim '(#\Space #\Tab #\Newline) env))))
    (let ((form (handler-case (asdf/source-registry:parse-source-registry-string env)
                  (error (e)
                    (msg "~&; cl-repo: WARNING: ignoring CL_SOURCE_REGISTRY: ~a~%" e)
                    nil))))
      (loop for entry in (rest form)
            for dir = (and (consp entry)
                           (member (first entry) '(:tree :directory))
                           (typep (second entry) '(or string pathname))
                           (uiop:ensure-directory-pathname (second entry)))
            when (and dir (uiop:absolute-pathname-p dir))
              collect (list (first entry) (namestring dir))))))

(defun source-registry-form (directories &key locked extra)
  ;; A checkout's leftover qlot tree (.qlot/ → Quicklisp releases) would make
  ;; every dependency resolve to a Quicklisp copy, which the walk rejects.
  ;; ASDF's :also-exclude matches directory names below each :tree root, so a
  ;; systems root that itself lives in .cl-repository/ is still scanned.
  ;; The install tree is preceded by the one version each multi-version
  ;; system should resolve to (PREFERRED-INSTALL-TREES).
  ;; EXTRA entries (EXPLICIT-SOURCE-REGISTRY-ENTRIES) follow the first
  ;; directory, the project: they shadow installed copies, not the checkout.
  (let ((root (ignore-errors (systems-root))))
    `(:source-registry
      (:also-exclude ".qlot")
      ;; A package published before the packager dropped .cl-repository/
      ;; (mcp-backend-streamable-http 0.2.0) carries a whole old client tree:
      ;; its cl-oci 0.16.0 was recompiled over the running one.
      (:also-exclude ".cl-repository")
      ,@(loop for dir in directories
              for first = t then nil
              for tree = (uiop:ensure-directory-pathname dir)
              append (if (and root (uiop:pathname-equal tree root))
                         (append (cl-repository-client/asdf-integration:preferred-install-trees
                                  tree locked)
                                 (list (list :tree (namestring tree))))
                         (list (list :tree (namestring tree))))
              when first append (copy-list extra))
      :ignore-inherited-configuration)))

(defun locked-versions (directory)
  "Alist system → version from DIRECTORY's cl-repo.lock, or NIL."
  (let ((path (lockfile-path directory)))
    (when (probe-file path)
      (ignore-errors
       (mapcar (lambda (e) (cons (lockfile-entry-system e) (lockfile-entry-version e)))
               (read-lockfile path))))))

(defun project-registry-directories (directory)
  "Trees the project registry searches: DIRECTORY, the installed systems,
   the client tree, and the client install tree (CL_REPOSITORY_DEST).
   On the ci-base image CL_REPOSITORY_CLIENT_DIR is only the client package;
   its own deps (alexandria, cl-ppcre, …) sit beside it under
   CL_REPOSITORY_DEST. Without that tree they stay loaded but unfindable,
   so the dependency walk reports them missing while the plan skips them
   as already loaded."
  (remove-duplicates
   (remove nil
           (list (uiop:ensure-directory-pathname directory)
                 (let ((root (systems-root)))
                   (when (probe-file root) root))
                 (ignore-errors (client-source-tree))
                 (uiop:getenv-absolute-directory "CL_REPOSITORY_DEST")))
   :test #'uiop:pathname-equal
   :from-end t))

(defun register-project (directory)
  "Register the project, the installed systems, and the client trees.
   Does not export CL_SOURCE_REGISTRY and does not inherit configuration:
   only its explicit trees (EXPLICIT-SOURCE-REGISTRY-ENTRIES) are kept."
  (setf cl-repository-client/asdf-integration:*locked-versions* (locked-versions directory))
  (asdf:initialize-source-registry
   (source-registry-form (project-registry-directories directory)
                         :locked cl-repository-client/asdf-integration:*locked-versions*
                         :extra (explicit-source-registry-entries))))

(defun top-level-asds (directory)
  (directory (merge-pathnames "*.asd" (uiop:ensure-directory-pathname directory))))

(defun secondary-system-name-p (name)
  (find #\/ name))

(defun discover-project-system (&optional (directory (uiop:getcwd)))
  "The project system. NIL when the directory has a qlfile and no .asd.
   Errors when several primary systems do not match the directory name."
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (names (remove-if #'secondary-system-name-p
                           (mapcar #'pathname-name (top-level-asds dir))))
         (dir-name (car (last (pathname-directory dir)))))
    (cond
      ((null names)
       (if (probe-file (merge-pathnames "qlfile" dir))
           nil
           (error "cl-repo: no .asd and no qlfile in ~a" dir)))
      ((= (length names) 1) (first names))
      ((and dir-name (find dir-name names :test #'string-equal))
       (find dir-name names :test #'string-equal))
      (t (error "cl-repo: ambiguous systems ~s in ~a" names dir)))))

(defun project-primary-systems (&optional (directory (uiop:getcwd)))
  "Every primary system the top-level .asd files of DIRECTORY name, the one
   matching the directory first. NIL for a qlfile-only project."
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (names (sort (remove-if #'secondary-system-name-p
                                 (mapcar #'pathname-name (top-level-asds dir)))
                      #'string<))
         (dir-name (car (last (pathname-directory dir))))
         (main (and dir-name (find dir-name names :test #'string-equal))))
    (if main
        (cons main (remove main names :test #'string-equal))
        names)))

(defun project-secondary-systems (primary &optional (directory (uiop:getcwd)))
  "The secondary systems (\"foo/agent\", \"foo/tests\") of PRIMARY that its
   .asd in DIRECTORY defines, sorted. Call after ASDF has read that .asd."
  (let ((dir (uiop:truename* (uiop:ensure-directory-pathname directory)))
        (primary (string-downcase primary)))
    (sort (loop for name in (asdf:registered-systems)
                for system = (and (string/= name primary)
                                  (string= (asdf:primary-system-name name) primary)
                                  (asdf:registered-system name))
                for file = (and system (asdf:system-source-file system))
                when (and file
                          (uiop:pathname-equal (uiop:truename* (uiop:pathname-directory-pathname file)) dir))
                  collect name)
          #'string<)))

(defun system-properties (system)
  (slot-value system (find-symbol (string '#:properties) (find-package :asdf/component))))

(defun cl-repo-plist (system-name)
  (let* ((system (asdf:find-system system-name nil))
         (props (and system (system-properties system))))
    (etypecase (first props)
      (keyword (getf props :cl-repo))
      (cons (cdr (assoc :cl-repo props :test #'eq)))
      (null nil))))

(defun expand-ci-env (env-specs)
  "Expand :ci :env. Returns (values systems-to-install systems-to-load)."
  (let ((install nil)
        (load nil))
    (dolist (spec env-specs)
      (let* ((var (string (first spec)))
             (options (rest spec))
             (value (or (uiop:getenv var) (getf options :default)))
             (systems (getf options :systems)))
        (unless value
          (error "cl-repo: environment variable ~a is unset and has no :default" var))
        (let ((match (find value systems :key #'first :test #'string-equal)))
          (unless match
            (error "cl-repo: ~a=~a is not one of ~{~a~^, ~}"
                   var value (mapcar #'first systems)))
          (when (getf options :install)
            (push (second match) install))
          (when (getf options :load-before-test)
            (push (second match) load)))))
    (values (nreverse install) (nreverse load))))

(defun ci-plist (system-name)
  (getf (cl-repo-plist system-name) :ci))

(defun project-with (system-name)
  (mapcar (lambda (name) (string-downcase (string name)))
          (uiop:ensure-list (getf (ci-plist system-name) :with))))

(defun project-load-before-test (system-name)
  (mapcar (lambda (name) (string-downcase (string name)))
          (uiop:ensure-list (getf (ci-plist system-name) :load-before-test))))

(defun clear-project-systems (directory)
  (dolist (asd (top-level-asds directory))
    (asdf:clear-system (pathname-name asd))))

(defun ensure-publish-tools ()
  (let ((tree (client-source-tree))
        (saved asdf:*source-registry-parameter*))
    (unwind-protect
         (progn
           (asdf:initialize-source-registry (source-registry-form (list tree)))
           (with-loaded-systems-pinned ()
             (asdf:load-system "cl-repository-packager")
             (asdf:load-system "cl-repository-ql-exporter")))
      (when saved
        (asdf:initialize-source-registry saved)))))

(defvar *installed-locally* nil
  "Set by a publish that could not push and installed the source locally.")

(defun note-installed-locally (name version dir)
  (setf *installed-locally* t)
  (msg "~&; cl-repo: WARNING: no write access to ~a/~a; installed ~a ~a locally (~a), ~
        unpublished. Publish it through cl-stack-systems imports to share it.~%"
       *default-registry* *default-namespace* name version (namestring dir)))

(defun install-release-locally (project version archive)
  "Unpack a downloaded Quicklisp release (tar.gz octets) into the install tree."
  (let ((dir (system-install-path project version)))
    (ensure-directories-exist dir)
    (extract-layer archive dir)
    (note-installed-locally project version dir)
    dir))

(defun copy-source-tree (from to)
  "Copy the files under FROM into TO, skipping VCS and cl-repo state."
  (let ((from (uiop:ensure-directory-pathname from))
        (to (uiop:ensure-directory-pathname to)))
    (ensure-directories-exist to)
    (dolist (f (uiop:directory-files from))
      (uiop:copy-file f (merge-pathnames (file-namestring f) to)))
    (dolist (d (uiop:subdirectories from))
      (let ((name (car (last (pathname-directory d)))))
        (unless (member name '(".git" ".cl-repository" ".qlot") :test #'string=)
          (copy-source-tree d (merge-pathnames (format nil "~a/" name) to)))))))

(defun publish-ql-system (name dist-url)
  (ensure-publish-tools)
  (handler-bind ((auth-error
                   (lambda (c)
                     (declare (ignore c))
                     (let ((r (find-restart (find-symbol "INSTALL-LOCALLY"
                                                         :cl-repository-ql-exporter/exporter))))
                       (when r (invoke-restart r #'install-release-locally))))))
    (uiop:symbol-call :cl-repository-ql-exporter/exporter :export-dist
                      dist-url *default-registry*
                      :namespace *default-namespace*
                      :filter name
                      :incremental t)))

(defun publish-source-dir (source-dir &key system-name source-url revision ref)
  (ensure-publish-tools)
  (multiple-value-bind (spec result)
      (uiop:symbol-call :cl-repository-packager/source-adapter :build-package-from-source
                        source-dir :system-name system-name :source-url source-url
                        :revision revision :version ref)
    (let ((tag (or (funcall (find-symbol "PACKAGE-SPEC-VERSION"
                                         :cl-repository-packager/build-matrix)
                            spec)
                   ref
                   "latest")))
      (let ((name (funcall (find-symbol "PACKAGE-SPEC-NAME" :cl-repository-packager/build-matrix)
                           spec)))
        (handler-case
            (uiop:symbol-call :cl-repository-packager/publisher :publish-package
                              *default-registry* *default-namespace* tag result spec)
          (auth-error ()
            (let ((dir (system-install-path name tag)))
              (copy-source-tree source-dir dir)
              (note-installed-locally name tag dir))))
        name))))

(defun install-or-publish (reference publish)
  "Install REFERENCE. When the registry has no such package, call PUBLISH and
   install the bare name. Absent = 404, or the 401/403 GHCR gives an anonymous
   pull of a repository that does not exist. Any other failure (network, TLS,
   a broken layer) propagates: publishing would not fix it."
  (when (handler-case
            (progn (cmd-install reference :registry-url *default-registry*
                                :namespace *default-namespace*)
                   nil)
          (registry-error (e)
            (unless (typep e '(or not-found-error auth-error))
              (error e))
            (msg "~&; cl-repo: ~a is not in ~a/~a; publishing it~%"
                 reference *default-registry* *default-namespace*)
            t))
    (let ((*installed-locally* nil))
      (funcall publish)
      (if *installed-locally*
          (configure-asdf-source-registry)
          (let ((name (subseq reference 0 (or (position #\: reference) (length reference)))))
            (cmd-install name :registry-url *default-registry* :namespace *default-namespace*)))))
  t)

(defun ql-entry-reference (name ref)
  "OCI reference for a qlfile `ql NAME` entry. A qlot lock records the
   Quicklisp dist date (\"ql-2025-06-22\"), never an OCI tag: packages are
   tagged with their .asd version, so a dist ref installs the latest."
  (if (or (null ref)
          (string-equal ref "latest")
          (and (> (length ref) 3) (string-equal "ql-" ref :end2 3)))
      name
      (format nil "~a:~a" name ref)))

(defun repo-system-name (repo)
  (let ((slash (position #\/ repo :from-end t)))
    (if slash (subseq repo (1+ slash)) repo)))

(defun install-or-latest (reference name)
  "Install REFERENCE, or the latest NAME when the registry has no such tag."
  (handler-case (cmd-install reference :registry-url *default-registry*
                                       :namespace *default-namespace*)
    (registry-error (e)
      (unless (typep e '(or not-found-error auth-error))
        (error e))
      (msg "~&; cl-repo: ~a has no OCI tag (a qlot lock commit); installing the latest ~a~%"
           reference name)
      (cmd-install name :registry-url *default-registry* :namespace *default-namespace*)))
  t)

(defun sync-github-entry (entry directory)
  (declare (ignore directory))
  (let* ((repo (qlot-entry-name entry))
         (ref (qlot-entry-ref entry))
         (system (repo-system-name repo))
         (reference (if ref (format nil "~a:~a" system ref) system)))
    ;; A commit qlot only recorded is not a pin the qlfile asked for, and OCI
    ;; packages are tagged with their .asd version: publishing every locked
    ;; commit of a first-party repo would push a sha tag per dependency.
    (when (qlot-entry-snapshot entry)
      (return-from sync-github-entry (install-or-latest reference system)))
    (install-or-publish
     reference
     (lambda ()
       (ensure-publish-tools)
       (multiple-value-bind (source-dir revision cleanup)
           (uiop:symbol-call :cl-repository-packager/source-adapter :clone-git-source
                             (if (search "://" repo)
                                 repo
                                 (format nil "https://github.com/~a.git" repo))
                             :ref ref)
         (unwind-protect
              (progn
                (when (probe-file (merge-pathnames "qlfile" source-dir))
                  (cmd-sync :directory source-dir :overlay *requested-overlay*))
                (publish-source-dir source-dir
                                    :system-name system
                                    :source-url (if (search "://" repo) repo
                                                    (format nil "https://github.com/~a" repo))
                                    :revision revision
                                    :ref ref))
           (when cleanup (funcall cleanup))))))))

(defun sync-qlot-entry (entry directory dist-url)
  (case (qlot-entry-kind entry)
    (:dist nil)
    (:ql
     (let* ((name (qlot-entry-name entry))
            (reference (ql-entry-reference name (qlot-entry-ref entry))))
       (install-or-publish reference
                           (lambda () (publish-ql-system name dist-url)))))
    ((:github :git)
     (sync-github-entry entry directory))
    (:http
     (let ((url (qlot-entry-ref entry)))
       (install-or-publish (qlot-entry-name entry)
                           (lambda ()
                             (let ((root (uiop:ensure-directory-pathname
                                          (merge-pathnames (format nil "cl-repo-http-~a/"
                                                                   (get-universal-time))
                                                           (uiop:temporary-directory)))))
                               (ensure-directories-exist root)
                               (uiop:run-program
                                (list "curl" "-fsSL" url "-o" (namestring (merge-pathnames "pkg.tgz" root)))
                                :output t :error-output t)
                               (uiop:run-program
                                (list "tar" "-xzf" (namestring (merge-pathnames "pkg.tgz" root))
                                      "-C" (namestring root))
                                :output t :error-output t)
                               (publish-source-dir root :source-url url))))))
    (:local
     (let ((path (uiop:ensure-directory-pathname
                  (merge-pathnames (qlot-entry-ref entry)
                                   (uiop:ensure-directory-pathname directory)))))
       (unless (uiop:directory-exists-p path)
         (error "cl-repo: local dependency ~a does not exist" path))
       (cmd-sync :directory path :overlay *requested-overlay*)))
    (t (error "cl-repo: unsupported qlfile entry ~a" (qlot-entry-kind entry)))))

(defun sync-qlfile (directory)
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (qlfile (merge-pathnames "qlfile" dir))
         (lock (merge-pathnames "qlfile.lock" dir)))
    (unless (probe-file qlfile)
      (return-from sync-qlfile nil))
    (let ((entries (if (probe-file lock) (read-qlfile-lock lock) (read-qlfile qlfile)))
          (dist-url *default-ql-dist*))
      (dolist (entry entries)
        (if (eq (qlot-entry-kind entry) :dist)
            (when (qlot-entry-ref entry)
              (setf dist-url (qlot-entry-ref entry)))
            (sync-qlot-entry entry dir dist-url))))))

(defun overlay-request (overlay)
  "NIL for the automatic stack. A name selects that opt-in overlay."
  (cond ((or (null overlay) (eq overlay t)) nil)
        ((stringp overlay) overlay)
        (t (string-downcase (string overlay)))))

(define-condition extension-upgrade-failed (error)
  ((name :initarg :name :reader extension-upgrade-failed-name)
   (minimum :initarg :minimum :reader extension-upgrade-failed-minimum)
   (loaded :initarg :loaded :reader extension-upgrade-failed-loaded))
  (:report (lambda (c s)
             (format s "cl-repo: the project's .asd needs ~a >= ~a in this image, which runs ~a. "
                     (extension-upgrade-failed-name c)
                     (extension-upgrade-failed-minimum c)
                     (extension-upgrade-failed-loaded c))
             (format s "Loading the newer copy from the install tree did not take; reinstall the client."))))

(define-condition client-runs-older-system (error)
  ((name :initarg :name :reader older-system-name)
   (loaded :initarg :loaded :reader older-system-loaded-version)
   (required :initarg :required :reader older-system-required-version)
   (loaded-file :initarg :loaded-file :initform nil :reader older-system-loaded-file))
  (:documentation "The project needs a newer NAME than the one this client image
runs, and NAME owns native libraries, so it cannot be replaced in a running
image. CONTINUE uses the loaded copy.")
  (:report (lambda (c s)
             (format s "cl-repo: the project needs ~a >= ~a, but this cl-repo client runs ~a ~a~@[ (~a)~]. "
                     (older-system-name c) (older-system-required-version c)
                     (older-system-name c) (older-system-loaded-version c)
                     (older-system-loaded-file c))
             (format s "It loads native libraries, so it cannot be replaced in a running image. ")
             (format s "Upgrade the client (curl -fsSL https://raw.githubusercontent.com/egao1980/cl-repository/main/install.sh | bash), ")
             (format s "or run the work in a fresh image (cl-repo test without CL_REPO_TEST_IN_PROCESS)."))))

(defvar *reload-unsafe-systems* '("cl+ssl")
  "Systems never reloaded in a running client although no native library lives
   in their own tree: cl+ssl opens cl-stack-ssl's libcrypto, and its reload
   unloaded the live library (http-backend-async#44).")

(defun loaded-system-version (name)
  (let ((sys (asdf:registered-system name)))
    (and sys (asdf:component-loaded-p sys) (asdf:component-version sys))))

(defun %under-directory-p (path dir)
  (let ((p (uiop:truename* path)) (d (uiop:truename* dir)))
    (and p d (uiop:subpathp p d))))

(defun reload-safe-system-p (name)
  "True when reloading NAME cannot close or reopen native code: no loaded
   foreign library lives under its directory, it declares no asdf-native
   :NATIVE-LIBRARY component, and it is not in *RELOAD-UNSAFE-SYSTEMS*."
  (let* ((name (string-downcase (string name)))
         (sys (asdf:registered-system name))
         (dir (and sys (asdf:system-source-directory sys)))
         (native-class (and (find-package "ASDF-NATIVE")
                            (find-class (find-symbol "NATIVE-LIBRARY" "ASDF-NATIVE") nil))))
    (not (or (member (asdf:primary-system-name name) *reload-unsafe-systems* :test #'string=)
             (and sys native-class
                  (some (lambda (c) (typep c native-class)) (asdf:component-children sys)))
             (and dir (find-package "CFFI")
                  (some (lambda (lib)
                          (let ((path (uiop:symbol-call "CFFI" "FOREIGN-LIBRARY-PATHNAME" lib)))
                            (and path (%under-directory-p path dir))))
                        (uiop:symbol-call "CFFI" "LIST-FOREIGN-LIBRARIES" :loaded-only t)))))))

(defun ensure-loaded-at-least (name minimum)
  "When this image runs a pinned NAME older than MINIMUM: upgrade it in place
   if RELOAD-SAFE-SYSTEM-P, else signal CLIENT-RUNS-OLDER-SYSTEM (CONTINUE keeps
   the loaded copy)."
  (let ((loaded (loaded-system-version name)))
    (when (and loaded (pinned-system-p name)
               (version< (princ-to-string loaded) (princ-to-string minimum)))
      (if (reload-safe-system-p name)
          (upgrade-loaded-extension name minimum)
          (cerror "Use the loaded copy anyway." 'client-runs-older-system
                  :name name :loaded loaded :required minimum
                  :loaded-file (let ((sys (asdf:registered-system name)))
                                 (and sys (asdf:system-source-file sys))))))))

(defun required-minimums (roots)
  "(name . version) for every (:version name min) in the :depends-on closure of
   ROOTS that ASDF can find, keeping the highest minimum per name. Reads .asd
   files; loads no code."
  (let ((seen (make-hash-table :test #'equal))
        (mins (make-hash-table :test #'equal)))
    (labels ((walk (name)
               (let ((name (string-downcase (string name))))
                 (unless (gethash name seen)
                   (setf (gethash name seen) t)
                   (let ((sys (asdf:find-system name nil)))
                     (when sys
                       (dolist (spec (asdf:system-depends-on sys))
                         (multiple-value-bind (dep min) (asdf-dep-spec spec)
                           (when dep
                             (when min (note-minimum mins (string-downcase dep) min))
                             (walk dep))))))))))
      (mapc #'walk roots))
    (loop for k being the hash-keys of mins using (hash-value v) collect (cons k v))))

(defun ensure-project-requirements (roots)
  "Before loading project code into this image: every pinned system ROOTS need
   newer is upgraded (pure Lisp) or reported (native; CLIENT-RUNS-OLDER-SYSTEM)."
  (loop for (name . min) in (required-minimums roots)
        do (ensure-loaded-at-least name min)))

(defun upgrade-loaded-extension (name minimum)
  "Load NAME >= MINIMUM over the copy this image runs. Only for systems that
   RELOAD-SAFE-SYSTEM-P accepts; see ENSURE-LOADED-AT-LEAST. Signals
   EXTENSION-UPGRADE-FAILED when the loaded version is still below MINIMUM."
  (let ((before (loaded-system-version name)))
    (when (and before (version< (princ-to-string before) (princ-to-string minimum)))
      (msg "~&; cl-repo: upgrading the loaded ~a ~a to >= ~a~%" name before minimum)
      (unpin-system name)
      (asdf:clear-system name)
      (configure-asdf-source-registry)
      (asdf:load-system name)
      (let ((after (loaded-system-version name)))
        (when (or (null after) (version< (princ-to-string after) (princ-to-string minimum)))
          (error 'extension-upgrade-failed :name name :minimum minimum
                                           :loaded (or after before)))))))

(defun ensure-defsystem-depends-on (directory)
  "Install the :defsystem-depends-on systems (asdf-native, cffi-grovel, ...) of
the .asd files in DIRECTORY that ASDF can't find, or finds older than a
(:version name min) entry asks for. ASDF loads them while reading the .asd,
before any :depends-on walk can see them. → the names installed.
An extension this image already runs below the minimum (the client's own
asdf-native) is upgraded in place: unpinned, cleared and loaded from the
install tree, since the project's .asd is read in this image."
  (let ((wanted '()) (minimums '()))
    (dolist (asd (top-level-asds (uiop:ensure-directory-pathname directory)))
      (multiple-value-bind (names mins) (asd-defsystem-depends-on asd)
        (dolist (n names) (pushnew n wanted :test #'string=))
        (dolist (m mins)
          (let ((prev (assoc (car m) minimums :test #'string=)))
            (if prev
                (when (version< (cdr prev) (cdr m)) (setf (cdr prev) (cdr m)))
                (push m minimums))))))
    (let ((missing (remove-if (lambda (n)
                                (system-satisfied-p n (cdr (assoc n minimums :test #'string=))))
                              (reverse wanted))))
      (dolist (n missing)
        (let ((min (cdr (assoc n minimums :test #'string=))))
          (msg "~&; cl-repo: installing :defsystem-depends-on ~a~@[ (>= ~a)~]~%" n min)
          (apply #'ensure-systems (list n) :default-source :oci
                 (when min (list :minimum min)))
          (when min
            (ensure-loaded-at-least n min))))
      missing)))

(defvar *sync-with* nil
  "Extra install roots for CMD-SYNC beyond the .asd :ci :with list: the CI
   action's `with:` input and what pre-install hooks push onto
   cl-repository-ci-lib:*extra-with* (an event backend chosen by env).")

(defun cmd-sync (&key (directory (uiop:getcwd)) system overlay locked)
  "Install what the .asd and qlfile ask for, and record the lock.
   Without SYSTEM, every system the project's top-level .asd files define:
   each primary system, with its secondary systems (\"foo/agent\") as local
   roots whose dependencies are walked too. SYSTEM limits the walk to it.
   OVERLAY names an opt-in overlay such as cuda, installed on top of the automatic stack.
   LOCKED installs cl-repo.lock."
  (let ((dir (uiop:ensure-directory-pathname directory))
        (*requested-overlay* (overlay-request overlay)))
    (when (member (namestring dir) *sync-stack* :test #'equal)
      (return-from cmd-sync nil))
    ;; Pinned from the start: the walk's FIND-SYSTEM under the project registry
    ;; would otherwise re-register a system this image runs (cl+ssl) from the
    ;; install tree, and a later load would load it, and its library, again.
    (with-loaded-systems-pinned (:except (list dir))
      (let ((*sync-stack* (cons (namestring dir) *sync-stack*)))
        (ensure-default-registry)
        (register-project dir)
        (clear-project-systems dir)
        (if locked
            (cmd-restore :registry-url *default-registry* :namespace *default-namespace*)
            (progn
              (sync-qlfile dir)
              (register-project dir)
              (let ((names (cond (system (list system))
                                 ((project-primary-systems dir))
                                 ;; No .asd: NIL with a qlfile, an error without one.
                                 (t (discover-project-system dir) nil))))
                (when names
                  (ensure-defsystem-depends-on dir))
                (dolist (name names)
                  (asdf:find-system name nil)
                  (multiple-value-bind (env-install env-load)
                      (expand-ci-env (getf (ci-plist name) :env))
                    (declare (ignore env-load))
                    (ensure-system-dependencies
                     name
                     :with (append (project-with name) env-install *sync-with*
                                   (unless system
                                     (project-secondary-systems name dir)))
                     :also-tests (getf (ci-plist name) :also-tests t)))))))))))

(defun test-setup (directory system)
  "Put the project's install tree on the registry. Returns the system name and
   the systems to load before it (:load-before-test, :ci :env loads)."
  (let ((name (or system (discover-project-system directory))))
    (unless name
      (error "cl-repo: no system to test in ~a" directory))
    (register-project directory)
    (configure-asdf-source-registry)
    (multiple-value-bind (env-install env-load)
        (expand-ci-env (getf (ci-plist name) :env))
      (declare (ignore env-install))
      (values name (append (project-load-before-test name) env-load)))))

(defun prepare-test (&key (directory (uiop:getcwd)) system)
  "Make the project's install tree visible to ASDF, load init files and the
   :load-before-test systems. Returns the system name. After this, everything
   cl-repo sync installed (including :ci :with extras) can be loaded.
   Runs in this image, so a pinned system the project needs newer is upgraded
   or reported first (ENSURE-PROJECT-REQUIREMENTS)."
  (multiple-value-bind (name extras) (test-setup directory system)
    (ensure-project-requirements
     (append (list name) extras
             (let ((tests (format nil "~a/tests" name)))
               (and (asdf:find-system tests nil) (list tests)))))
    (dolist (extra extras)
      (asdf:load-system extra))
    name))

(defvar *test-in-subprocess*
  (not (member (uiop:getenv "CL_REPO_TEST_IN_PROCESS") '("1" "true" "yes") :test #'equal))
  "When true, CMD-TEST runs the suite in a fresh image of this Lisp that only
   gets the source registry. The client's own systems (dexador, cl+ssl and
   the OpenSSL it opened) then never meet the code under test.
   CL_REPO_TEST_IN_PROCESS=1 sets it to NIL.")

(define-condition tests-failed (error)
  ((system :initarg :system :reader tests-failed-system)
   (exit-code :initarg :exit-code :reader tests-failed-exit-code))
  (:report (lambda (c s)
             (format s "cl-repo: testing ~a failed (exit code ~d)"
                     (tests-failed-system c) (tests-failed-exit-code c)))))

(defun test-image-command ()
  "Program and options that start a fresh image of the running SBCL, or NIL
   (another Lisp, or an executable with its core embedded: such a binary
   ignores --core and would start the client again)."
  #+sbcl
  (let ((runtime sb-ext:*runtime-pathname*)
        (core sb-ext:*core-pathname*))
    (when (and runtime core (probe-file runtime) (probe-file core)
               (not (uiop:pathname-equal (truename runtime) (truename core))))
      (list (uiop:native-namestring runtime)
            "--core" (uiop:native-namestring core) "--noinform"
            "--dynamic-space-size"
            (format nil "~DMB" (floor (sb-ext:dynamic-space-size) (* 1024 1024)))
            "--non-interactive" "--no-sysinit" "--no-userinit")))
  #-sbcl nil)

(defun asdf-require-form ()
  "Load ASDF in the test image from this SBCL's contrib, as the client did."
  (let* ((home-fn (find-symbol "SBCL-HOMEDIR-PATHNAME" "SB-INT"))
         (home (and home-fn (ignore-errors (funcall home-fn))))
         (fasl (and home (probe-file (merge-pathnames "contrib/asdf.fasl" home)))))
    (if fasl
        (format nil "(load ~S)" (uiop:native-namestring fasl))
        "(require :asdf)")))

(defun namestrings (form)
  "FORM with each pathname replaced by its namestring, so it prints readably."
  (cond ((pathnamep form) (namestring form))
        ((consp form) (cons (namestrings (car form)) (namestrings (cdr form))))
        (t form)))

(defun test-image-forms (name extras pre-test-file)
  "The --eval forms of the test image, as strings. Each is read only when the
   one before has run, so the ASDF package exists by the second."
  (with-standard-io-syntax
    (remove nil
            (list (asdf-require-form)
                  (format nil "(asdf:initialize-source-registry '~S)"
                          (namestrings asdf/source-registry:*source-registry-parameter*))
                  (when extras
                    (format nil "(dolist (s '~S) (asdf:load-system s))" extras))
                  (when pre-test-file
                    (format nil "(load ~S)" (uiop:native-namestring pre-test-file)))
                  (format nil "(asdf:load-system ~S)" name)
                  (format nil "(asdf:test-system ~S)" name)))))

(defun run-test-image (command name extras pre-test-file)
  (msg "~&; cl-repo: testing ~a in a fresh image~%" name)
  (let ((code (nth-value 2 (uiop:run-program
                            (append command
                                    (loop for form in (test-image-forms name extras pre-test-file)
                                          append (list "--eval" form)))
                            :ignore-error-status t
                            :output :interactive
                            :error-output :interactive
                            :input :interactive))))
    (unless (zerop code)
      (error 'tests-failed :system name :exit-code code))
    name))

(defun cmd-test (&key (directory (uiop:getcwd)) system overlay (sync t) pre-test pre-test-file)
  "Sync, then asdf:test-system. A system with no test-op still exits 0.
   The suite runs in a fresh image (*TEST-IN-SUBPROCESS*); a failure signals
   TESTS-FAILED. PRE-TEST-FILE is loaded there once the install tree is on
   the registry and before the system loads (CI pre-test hooks). PRE-TEST, a
   function of no arguments, runs at that point too, but a function cannot
   cross into another image: passing one runs the suite in this image."
  (let ((command (and *test-in-subprocess* (not pre-test) (test-image-command)))
        (checkout (list (uiop:ensure-directory-pathname directory))))
    (if command
        (progn
          (when sync
            (with-loaded-systems-pinned (:except checkout)
              (cmd-sync :directory directory :system system :overlay overlay)))
          (multiple-value-bind (name extras) (test-setup directory system)
            (run-test-image command name extras pre-test-file)))
        ;; Systems this image already runs (the client's cl+ssl, cl-stack-ssl, ...)
        ;; stay where they were loaded from: a second copy from the install tree
        ;; re-ran cl+ssl's reload.lisp, which unloads the live libcrypto, and SBCL
        ;; crashed re-linking foreign symbols (http-backend-async#44 on ci-base).
        ;; The checkout itself is never pinned: its code is what is under test.
        (with-loaded-systems-pinned (:except checkout)
          (when sync
            (cmd-sync :directory directory :system system :overlay overlay))
          (let ((name (prepare-test :directory directory :system system)))
            (when pre-test
              (funcall pre-test))
            (when pre-test-file
              (load pre-test-file))
            (asdf:load-system name)
            (asdf:test-system name))))))

(defun lisp-startup (program form rest)
  (cond
    ((string-equal program "ros") (append (list "-e" form) rest))
    ((string-equal program "ecl") (append (list "-eval" form) rest))
    ((member program '("sbcl" "ccl" "abcl") :test #'string-equal)
     (append (list "--eval" form) rest))
    (t rest)))

(defun cmd-run (argv &key (directory (uiop:getcwd)) system overlay)
  "Sync (SYSTEM, else every project system), then exec ARGV. A lisp
   implementation is started with the source registry already configured.
   CL_SOURCE_REGISTRY is not exported. The startup form loads ASDF itself and
   names it only through FIND-SYMBOL, so it reads and runs whatever options
   come before it (ros +Q starts without ASDF)."
  (when (null argv)
    (error "cl-repo: run requires a command"))
  (cmd-sync :directory directory :system system :overlay overlay)
  (let* ((form (format nil "(progn (require \"asdf\") (funcall (find-symbol \"INITIALIZE-SOURCE-REGISTRY\" \"ASDF\") '~s))"
                       (source-registry-form (project-registry-directories directory)
                                             :locked (locked-versions directory)
                                             :extra (explicit-source-registry-entries))))
         (args (lisp-startup (first argv) form (rest argv)))
         (code (nth-value 2 (uiop:run-program (cons (first argv) args)
                                              :ignore-error-status t
                                              :output :interactive
                                              :error-output :interactive
                                              :input :interactive))))
    (unless (zerop code)
      (uiop:quit code))))

(defparameter *lisp-commands* '("ros" "sbcl" "ccl" "ecl" "abcl")
  "Commands that `cl-repo <lisp> …` runs as `cl-repo run -- <lisp> …`.")

(defun lisp-command-p (name)
  (and (stringp name) (member name *lisp-commands* :test #'string-equal) t))

(defun split-lisp-command-args (args)
  "Split the arguments after `cl-repo <lisp>`. Leading --system NAME and
   --overlay NAME are cl-repo's; the rest goes to the lisp unchanged (its own
   -l, -q, --, --help, `ros run`). Here --overlay always takes a name, so a
   following word such as `run` is never mistaken for one.
   Returns (values lisp-args system overlay)."
  (let ((system nil) (overlay nil))
    (loop
      (let ((arg (first args)))
        (cond ((and (member arg '("--system" "--overlay") :test #'equal)
                    (rest args))
               (if (equal arg "--system")
                   (setf system (second args))
                   (setf overlay (second args)))
               (setf args (cddr args)))
              (t (return (values args system overlay))))))))

(defun expand-lisp-command (argv)
  "`cl-repo ros …` → `cl-repo run [--system S] [--overlay O] -- ros …`.
   Other ARGV is returned unchanged."
  (if (lisp-command-p (first argv))
      (multiple-value-bind (lisp-args system overlay)
          (split-lisp-command-args (rest argv))
        (append (list "run")
                (when system (list "--system" system))
                (when overlay (list "--overlay" overlay))
                (list "--" (first argv))
                lisp-args))
      argv))

(defun machine-overlay-key (directory)
  (multiple-value-bind (os arch impl) (detect-local-platform)
    (let ((stack (ignore-errors
                  (choose-overlay-plists (read-system-overlays directory)
                                         :os os :arch arch :implementation impl))))
      (or (let ((top (car (last stack))))
            (when top
              (let ((plat (getf top :platform)))
                (overlay-key :os (getf plat :os) :arch (getf plat :arch) :lisp (getf plat :lisp)))))
          (overlay-key :os os :arch arch)))))

(defun cmd-grovel (&key (directory (uiop:getcwd)) system overlay)
  "Sync and load the system so cffi-grovel runs. The grovel directory of the
   most specific matching overlay is created for the output. The load runs in
   this image with the client's systems pinned, so it never reloads one of
   them from the install tree; one the project needs newer is upgraded or
   reported first (ENSURE-PROJECT-REQUIREMENTS)."
  (cmd-sync :directory directory :system system :overlay overlay)
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (name (or system (discover-project-system dir)))
         (key (machine-overlay-key dir))
         (out (merge-pathnames (format nil "grovel/~a/" key) dir)))
    (ensure-directories-exist (merge-pathnames ".keep" out))
    (when name
      (with-loaded-systems-pinned (:except (list dir))
        (ensure-project-requirements (list name))
        (asdf:load-system name)))
    out))
