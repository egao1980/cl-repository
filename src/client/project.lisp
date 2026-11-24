(defpackage :cl-repository-client/project
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-repository-client/commands
                #:cmd-install #:cmd-restore
                #:*default-registry* #:*default-namespace*)
  (:import-from :cl-repository-client/quickload
                #:add-registry #:ensure-system-dependencies #:ensure-systems
                #:dependency-closure #:collect-missing-asdf-deps #:installed-satisfies-p
                #:*install-recorder*)
  (:import-from :cl-repository-client/asd-rewrite #:asd-defsystem-depends-on)
  (:import-from :cl-oci-client/conditions #:registry-error #:not-found-error #:auth-error
                #:credentials-rejected)
  (:import-from :cl-oci-client/pin #:with-loaded-systems-pinned #:pinned-system-p #:unpin-system)
  (:import-from :cl-repository-client/dep-satisfy #:system-satisfied-p #:asdf-dep-spec #:note-minimum)
  (:import-from :cl-repository-client/version-utils #:version< #:select-preferred-version)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-path #:read-lockfile #:write-lockfile
                #:lockfile-entry-system #:lockfile-entry-version)
  (:import-from :cl-repository-client/sync-lock
                #:lockfile-not-current #:lockfile-stale-reason #:closure-lock-entries
                #:lockfile-closure-gap #:lockfile-policy-gap #:lockfile-reproduction-gap
                #:install-lockfile-entries)
  (:import-from :cl-repository-client/asdf-integration
                #:configure-asdf-source-registry #:output-translations-form #:fasl-lock-form)
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
           #:*use-lockfile*
           #:ensure-default-registry
           #:register-project
           #:project-registry-directories
           #:explicit-source-registry-entries
           #:source-registry-form
           #:discover-project-system
           #:ensure-defsystem-depends-on
           #:expand-ci-env
           #:project-closure
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
           #:expand-lisp-command
           #:client-release-version
           #:cmd-client-version))
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

(defun client-release-version (&optional (tree (ignore-errors (client-source-tree))))
  "The release version of the client in TREE (default: CLIENT-SOURCE-TREE),
   from its directory name. setup-client.sh, which install.sh runs, extracts
   release V into cl-oci-V/, the prefix the source layer's tarball carries.
   NIL for any other directory, such as a checkout."
  (when tree
    (let ((name (car (last (pathname-directory (uiop:ensure-directory-pathname tree))))))
      (when (stringp name)
        (loop for prefix in '("cl-oci-" "cl-repository-client-")
              for start = (length prefix)
              when (and (> (length name) start)
                        (string= prefix name :end2 start)
                        (digit-char-p (char name start))
                        (every (lambda (ch) (or (alphanumericp ch) (find ch ".+-")))
                               (subseq name start)))
                return (subseq name start))))))

(defun cmd-client-version (&optional (stream *standard-output*))
  "Print which client runs: cl-repo --version (#189). \"cl-repo 0.27.38
   (/home/me/.cl-repository-client/cl-oci-0.27.38/)\": the release version
   (CLIENT-RELEASE-VERSION) and the client's directory. A client that is not
   a release tree (a checkout) prints \"unknown version\"."
  (let ((tree (ignore-errors (client-source-tree))))
    (format stream "~&cl-repo ~a~@[ (~a)~]~%"
            (or (client-release-version tree) "unknown version")
            (and tree (uiop:native-namestring tree)))))

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

(defvar *use-lockfile* t
  "NIL while a sync or test runs with --no-lock: cl-repo.lock is neither read
   nor written, so the project registry prefers no locked version either.")

(defun locked-versions (directory)
  "Alist system → version from DIRECTORY's cl-repo.lock, or NIL (always NIL
   under --no-lock, *USE-LOCKFILE*)."
  (let ((path (lockfile-path directory)))
    (when (and *use-lockfile* (probe-file path))
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

(defun absent-package-error-p (e)
  "True when registry error E means the package is not there: 404, or a
   401/403 (GHCR's answer to an anonymous pull of a repository that does not
   exist). Refused credentials (CREDENTIALS-REJECTED) are not: they are a
   misconfiguration, and treating them as absent hides it (#186)."
  (and (typep e '(or not-found-error auth-error))
       (not (typep e 'credentials-rejected))))

(defun install-or-publish (reference publish)
  "Install REFERENCE. When the registry has no such package, call PUBLISH and
   install the bare name. Absent = 404, or the 401/403 GHCR gives an anonymous
   pull of a repository that does not exist (ABSENT-PACKAGE-ERROR-P). Any
   other failure (network, TLS, a broken layer, refused credentials)
   propagates: publishing would not fix it."
  (when (handler-case
            (progn (cmd-install reference :registry-url *default-registry*
                                :namespace *default-namespace*)
                   nil)
          (registry-error (e)
            (unless (absent-package-error-p e)
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
      (unless (absent-package-error-p e)
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
  "Install the entries of DIRECTORY's qlfile (its qlfile.lock when there is
   one). → T when there is a qlfile."
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
            (sync-qlot-entry entry dir dist-url)))
      t)))

(defun qlfile-system-names (directory)
  "The systems DIRECTORY's qlfile (or qlfile.lock) installs by name: its ql,
   http, github and git entries. NIL without a qlfile."
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (qlfile (merge-pathnames "qlfile" dir))
         (lock (merge-pathnames "qlfile.lock" dir)))
    (when (probe-file qlfile)
      (loop for entry in (if (probe-file lock) (read-qlfile-lock lock) (read-qlfile qlfile))
            for name = (case (qlot-entry-kind entry)
                         ((:ql :http) (qlot-entry-name entry))
                         ((:github :git) (repo-system-name (qlot-entry-name entry))))
            when (stringp name)
              collect (string-downcase name)))))

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

(defun defsystem-depends-on-requirements (directory)
  "(name . minimum) per :defsystem-depends-on system of the top-level .asd
   files in DIRECTORY, the highest (:version name min) asked for, or NIL."
  (let ((wanted '()) (minimums '()))
    (dolist (asd (top-level-asds (uiop:ensure-directory-pathname directory)))
      (multiple-value-bind (names mins) (asd-defsystem-depends-on asd)
        (dolist (n names) (pushnew n wanted :test #'string=))
        (dolist (m mins)
          (let ((prev (assoc (car m) minimums :test #'string=)))
            (if prev
                (when (version< (cdr prev) (cdr m)) (setf (cdr prev) (cdr m)))
                (push m minimums))))))
    (mapcar (lambda (n) (cons n (cdr (assoc n minimums :test #'string=))))
            (reverse wanted))))

(defun ensure-defsystem-depends-on (directory)
  "Install the :defsystem-depends-on systems (asdf-native, cffi-grovel, ...) of
the .asd files in DIRECTORY that ASDF can't find, or finds older than a
(:version name min) entry asks for. ASDF loads them while reading the .asd,
before any :depends-on walk can see them. → the names installed.
An extension this image already runs below the minimum (the client's own
asdf-native) is upgraded in place: unpinned, cleared and loaded from the
install tree, since the project's .asd is read in this image."
  (let ((missing (remove-if (lambda (requirement)
                              (system-satisfied-p (car requirement) (cdr requirement)))
                            (defsystem-depends-on-requirements directory))))
    (loop for (n . min) in missing
          do (msg "~&; cl-repo: installing :defsystem-depends-on ~a~@[ (>= ~a)~]~%" n min)
             (apply #'ensure-systems (list n) :default-source :oci
                    (when min (list :minimum min)))
             (when min
               (ensure-loaded-at-least n min)))
    (mapcar #'car missing)))

(defun locked-defsystem-depends-on-gap (directory)
  "ENSURE-DEFSYSTEM-DEPENDS-ON for a sync from the lock, which installs
   nothing: an extension this image runs below the minimum is upgraded from
   the install tree. → the :defsystem-depends-on names that are not
   installed new enough, NIL when none."
  (let ((gap '()))
    (loop for (n . min) in (defsystem-depends-on-requirements directory)
          unless (system-satisfied-p n min)
            do (if (and min (installed-satisfies-p n min))
                   (ensure-loaded-at-least n min)
                   (push n gap)))
    (nreverse gap)))

(defvar *sync-with* nil
  "Extra install roots for CMD-SYNC beyond the .asd :ci :with list: the CI
   action's `with:` input and what pre-install hooks push onto
   cl-repository-ci-lib:*extra-with* (an event backend chosen by env).")

(defun sync-system-names (dir system)
  "The project systems a sync of DIR walks: SYSTEM, else every primary system
   of the top-level .asd files. NIL for a qlfile-only project; an error when
   DIR has neither .asd nor qlfile."
  (cond (system (list system))
        ((project-primary-systems dir))
        (t (discover-project-system dir) nil)))

(defun sync-walk-options (name dir system)
  "Keyword arguments of the dependency walk for the project system NAME: its
   :ci :with and :env installs, *SYNC-WITH*, and (a whole-project sync, no
   SYSTEM) the secondary systems its .asd defines. Reads that .asd."
  (asdf:find-system name nil)
  (multiple-value-bind (env-install env-load)
      (expand-ci-env (getf (ci-plist name) :env))
    (declare (ignore env-load))
    (list :with (append (project-with name) env-install *sync-with*
                        (unless system
                          (project-secondary-systems name dir)))
          :also-tests (getf (ci-plist name) :also-tests t))))

(defun project-closure (dir &optional system)
  "(values closure missing) of the project in DIR, or of SYSTEM alone: every
   system name the sync's dependency walk reaches from the project systems
   and their extras, the .asd files' :defsystem-depends-on and the findable
   qlfile entries; and the names it finds unsatisfied. Reads .asd files and
   installs nothing."
  (let ((closure '()) (missing '()))
    (flet ((add (names unmet)
             (setf closure (union closure names :test #'string=)
                   missing (union missing unmet :test #'string=))))
      (dolist (name (sync-system-names dir system))
        (multiple-value-call #'add
                             (apply #'dependency-closure name (sync-walk-options name dir system))))
      (let ((extra (append (mapcar #'car (defsystem-depends-on-requirements dir))
                           (remove-if-not (lambda (name) (asdf:find-system name nil))
                                          (qlfile-system-names dir)))))
        (when extra
          (multiple-value-bind (unmet minimums names) (collect-missing-asdf-deps '() extra)
            (declare (ignore minimums))
            (add names unmet)))))
    (values closure missing)))

(defun sync-from-lockfile (dir system &key strict)
  "Install the project in DIR from its cl-repo.lock when the lock is current:
   no project .asd or qlfile is newer, source policy allows its entries, each
   entry not installed records a registry or digest to install it from
   (LOCKFILE-REPRODUCTION-GAP), and it locks every package the dependency
   walk (PROJECT-CLOSURE) reaches, at
   the version the registry then resolves. A version not installed is pulled
   by its tag after a digest check; nothing is resolved and no tag listed.
   → T when the lock was used, NIL when it is not current. With STRICT
   (--locked), a lock that is not current signals LOCKFILE-NOT-CURRENT."
  (let* ((path (lockfile-path dir))
         (reason (lockfile-stale-reason dir))
         (entries '()))
    (unless reason
      (handler-case (setf entries (read-lockfile path))
        (error (e)
          (setf reason (format nil "it cannot be read (~a)" e)))))
    (unless reason
      (setf reason (lockfile-policy-gap entries)))
    ;; an entry that records no registry or digest and is not installed here
    ;; came from a local-only install: resolve rather than pull a tag no
    ;; registry has (#163)
    (unless reason
      (setf reason (lockfile-reproduction-gap entries)))
    (unless reason
      (when (install-lockfile-entries entries)
        (register-project dir))
      (let ((gap (locked-defsystem-depends-on-gap dir)))
        (when gap
          (setf reason (format nil "~{~a~^, ~} (:defsystem-depends-on) not installed" gap)))))
    (unless reason
      (multiple-value-bind (closure missing) (project-closure dir system)
        (setf reason (if missing
                         (format nil "~{~a~^, ~} not installed or too old" missing)
                         (lockfile-closure-gap entries closure)))))
    (cond ((null reason)
           (msg "~&; cl-repo: dependencies from cl-repo.lock (~d package~:p)~%" (length entries))
           t)
          (strict
           (error 'lockfile-not-current :path path :reason reason))
          (t
           (when (probe-file path)
             (msg "~&; cl-repo: cl-repo.lock is not current (~a); resolving~%" reason))
           nil))))

(defun sync-resolving (dir system)
  "Install what the .asd files and qlfile of DIR ask for (SYSTEM only, when
   given), resolving what is missing against the registries. The qlfile's
   entries get their dependency closure too, as PROJECT-CLOSURE counts it: a
   qlfile-only project has no .asd to walk from, and its lock held the
   entries alone, so a fresh runner failed with Component not found (#170).
   A package the lock does not hold resolves to the newest published version
   (#167), except the qlfile's entries, installed at the reference it gives."
  (when (sync-qlfile dir)
    ;; a local or git entry synced another project, which registered itself
    (register-project dir))
  (let ((names (sync-system-names dir system))
        (entries (qlfile-system-names dir)))
    (when names
      (ensure-defsystem-depends-on dir))
    (dolist (name names)
      (apply #'ensure-system-dependencies name :newest t :keep entries
             (sync-walk-options name dir system)))
    ;; installed packages, not checkouts: no test systems, no :ci extras
    (dolist (name entries)
      (when (asdf:find-system name nil)
        (ensure-system-dependencies name :also-tests nil :newest t :keep entries)))))

(defun write-project-lock (dir system installs)
  "Write DIR's cl-repo.lock: the packages the project's dependency closure is
   loaded from, at the versions the registry resolves, which are the ones the
   test image and `cl-repo run` load. Digests come from INSTALLS (this sync's
   INSTALL-RESULTs) or the old lock where they can. With SYSTEM (a sync of one
   system) the old entries outside its closure are kept. → the entries."
  (let* ((path (lockfile-path dir))
         (previous (and (probe-file path) (ignore-errors (read-lockfile path))))
         (entries (closure-lock-entries (project-closure dir system)
                                        :installs installs :previous previous)))
    (when system
      (dolist (old previous)
        (unless (find (lockfile-entry-system old) entries
                      :key #'lockfile-entry-system :test #'string=)
          (push old entries)))
      (setf entries (sort entries #'string< :key #'lockfile-entry-system)))
    (write-lockfile entries path)
    (setf cl-repository-client/asdf-integration:*locked-versions*
          (mapcar (lambda (e) (cons (lockfile-entry-system e) (lockfile-entry-version e)))
                  entries))
    (msg "~&; cl-repo: wrote cl-repo.lock (~d package~:p)~%" (length entries))
    entries))

(defun cmd-sync (&key (directory (uiop:getcwd)) system overlay locked (lock t))
  "Install what the .asd and qlfile ask for.
   Without SYSTEM, every system the project's top-level .asd files define:
   each primary system, with its secondary systems (\"foo/agent\") as local
   roots whose dependencies are walked too. SYSTEM limits the walk to it.
   OVERLAY names an opt-in overlay such as cuda, installed on top of the automatic stack.
   cl-repo.lock: when it is current (SYNC-FROM-LOCKFILE), the dependencies
   are installed from it, with no resolution and no tag listing. Otherwise
   they are resolved and the closure is written to it (WRITE-PROJECT-LOCK).
   LOCKED T (--locked) installs from the lock and signals LOCKFILE-NOT-CURRENT
   rather than resolve. LOCKED :RESTORE (`cl-repo restore`) installs every
   entry of the lock again, current or not (CMD-RESTORE).
   LOCK NIL (--no-lock) resolves and neither reads nor writes the lock.
   A sync that another sync runs (a qlfile's local or git entry) resolves and
   leaves its lock alone."
  (when (and locked (not (and lock *use-lockfile*)))
    (error "cl-repo: --locked and --no-lock exclude each other"))
  (let ((dir (uiop:ensure-directory-pathname directory))
        (*requested-overlay* (overlay-request overlay)))
    (when (member (namestring dir) *sync-stack* :test #'equal)
      (return-from cmd-sync nil))
    (let* ((outer (null *sync-stack*))
           (*use-lockfile* (and *use-lockfile* lock))
           (installs '())
           ;; the lock is written from the closure; no install adds to it
           (*install-recorder* (if outer
                                   (lambda (result) (push result installs))
                                   *install-recorder*)))
      ;; Pinned from the start: the walk's FIND-SYSTEM under the project registry
      ;; would otherwise re-register a system this image runs (cl+ssl) from the
      ;; install tree, and a later load would load it, and its library, again.
      ;; No shadowing warning: the project runs in another image, which loads
      ;; the newer copy (#169). Inside a scope that runs it here (cl-repo test
      ;; in process, grovel) this is that scope, which warns.
      (with-loaded-systems-pinned (:except (list dir) :warn-shadowing nil)
        (let ((*sync-stack* (cons (namestring dir) *sync-stack*))
              ;; one registry cache for the whole sync (CL-REPOSITORY#136)
              (cl-repository-client/constraint-builder:*resolution-cache*
               (or cl-repository-client/constraint-builder:*resolution-cache*
                   (cl-repository-client/constraint-builder:make-resolution-cache)))
              (cl-oci-client/pull:*pull-cache*
               (or cl-oci-client/pull:*pull-cache* (make-hash-table :test 'equal))))
          (ensure-default-registry)
          (register-project dir)
          (clear-project-systems dir)
          (cond
           ((eq locked :restore)
            (cmd-restore :registry-url *default-registry* :namespace *default-namespace*))
           ((and outer *use-lockfile* (sync-from-lockfile dir system :strict locked)))
           (t
            (sync-resolving dir system)
            (when (and outer *use-lockfile* (not *dry-run*))
              (write-project-lock dir system installs)))))))))

(defun project-registered-p (directory)
  "True when the source registry is already the one REGISTER-PROJECT gives
   DIRECTORY, with the preferences its cl-repo.lock gives now. Every install
   is followed by a rescan, so the registry's contents are current too."
  (equal asdf/source-registry:*source-registry-parameter*
         (source-registry-form (project-registry-directories directory)
                               :locked (locked-versions directory)
                               :extra (explicit-source-registry-entries))))

(defun test-setup (directory system &key synced)
  "Put the project's install tree on the registry. Returns the system name and
   the systems to load before it (:load-before-test, :ci :env loads).
   SYNCED: CMD-SYNC has just set the registry up for DIRECTORY. It is kept
   when it is the one REGISTER-PROJECT would make (PROJECT-REGISTERED-P),
   which saves a scan of the install tree."
  (let ((name (or system (discover-project-system directory))))
    (unless name
      (error "cl-repo: no system to test in ~a" directory))
    (unless (and synced (project-registered-p directory))
      (register-project directory))
    (multiple-value-bind (env-install env-load)
        (expand-ci-env (getf (ci-plist name) :env))
      (declare (ignore env-install))
      (values name (append (project-load-before-test name) env-load)))))

(defun prepare-test (&key (directory (uiop:getcwd)) system synced)
  "Make the project's install tree visible to ASDF, load init files and the
   :load-before-test systems. Returns the system name. After this, everything
   cl-repo sync installed (including :ci :with extras) can be loaded.
   Runs in this image, so a pinned system the project needs newer is upgraded
   or reported first (ENSURE-PROJECT-REQUIREMENTS). SYNCED: see TEST-SETUP."
  (multiple-value-bind (name extras) (test-setup directory system :synced synced)
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
   one before has run, so the ASDF package exists by the second. The fasl
   lock (FASL-LOCK-FORM) is in place before anything compiles (#162)."
  (with-standard-io-syntax
    (remove nil
            (list (asdf-require-form)
                  (format nil "~S" (output-translations-form))
                  (let ((lock (fasl-lock-form)))
                    (when lock (format nil "~S" lock)))
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

(defun cmd-test (&key (directory (uiop:getcwd)) system overlay (sync t) pre-test pre-test-file
                      locked (lock t))
  "Sync, then asdf:test-system. A system with no test-op still exits 0.
   The suite runs in a fresh image (*TEST-IN-SUBPROCESS*); a failure signals
   TESTS-FAILED. PRE-TEST-FILE is loaded there once the install tree is on
   the registry and before the system loads (CI pre-test hooks). PRE-TEST, a
   function of no arguments, runs at that point too, but a function cannot
   cross into another image: passing one runs the suite in this image.
   LOCKED and LOCK are the sync's (--locked, --no-lock): with a current
   cl-repo.lock the sync installs from it and resolves nothing."
  (let ((command (and *test-in-subprocess* (not pre-test) (test-image-command)))
        (checkout (list (uiop:ensure-directory-pathname directory)))
        (*use-lockfile* (and *use-lockfile* lock)))
    (if command
        (progn
          (when sync
            ;; the suite runs in the fresh image, which loads the locked versions
            (with-loaded-systems-pinned (:except checkout :warn-shadowing nil)
              (cmd-sync :directory directory :system system :overlay overlay
                        :locked locked :lock lock)))
          (multiple-value-bind (name extras) (test-setup directory system :synced sync)
            (run-test-image command name extras pre-test-file)))
        ;; Systems this image already runs (the client's cl+ssl, cl-stack-ssl, ...)
        ;; stay where they were loaded from: a second copy from the install tree
        ;; re-ran cl+ssl's reload.lisp, which unloads the live libcrypto, and SBCL
        ;; crashed re-linking foreign symbols (http-backend-async#44 on ci-base).
        ;; The checkout itself is never pinned: its code is what is under test.
        (with-loaded-systems-pinned (:except checkout)
          (when sync
            (cmd-sync :directory directory :system system :overlay overlay
                      :locked locked :lock lock))
          (let ((name (prepare-test :directory directory :system system :synced sync)))
            (when pre-test
              (funcall pre-test))
            (when pre-test-file
              (load pre-test-file))
            (asdf:load-system name)
            (asdf:test-system name))))))

(defparameter *sbcl-runtime-options*
  '(("--core" . 1) ("--dynamic-space-size" . 1) ("--control-stack-size" . 1)
    ("--tls-limit" . 1) ("--noinform" . 0) ("--disable-ldb" . 0)
    ("--lose-on-corruption" . 0) ("--debug-environment" . 0)
    ("--merge-core-pages" . 0) ("--no-merge-core-pages" . 0)
    ("--help" . 0) ("--version" . 0))
  "SBCL C runtime options and how many arguments each takes. They must come
   before any toplevel option such as --eval.")

(defparameter *sbcl-script-runtime-options*
  '("--noinform" "--disable-ldb" "--lose-on-corruption" "--end-runtime-options")
  "What --script implies as a runtime option. Once a toplevel --eval precedes
   it, --script is only a toplevel option, so these are given explicitly.")

(defun sbcl-startup (form args)
  "ARGS with --eval FORM after SBCL's leading runtime options (#130): after
   --eval, --noinform is a fatal \"runtime option in the middle of Lisp
   options\" and --script no longer implies --noinform, so the banner reached
   stdout. `--script FILE` keeps its meaning: its runtime implications, then
   --eval FORM, then the toplevel `--script FILE` (no init files, debugger
   off, script stream handling), which must stay last as it ends the
   toplevel options."
  (let ((runtime '()))
    (loop
      (let* ((arg (first args))
             (entry (and (stringp arg) (assoc arg *sbcl-runtime-options* :test #'string=))))
        (cond
          ((equal arg "--end-runtime-options")
           (return (append (reverse runtime) (list arg "--eval" form) (rest args))))
          ((equal arg "--script")
           (return (append (reverse runtime)
                           (remove-if (lambda (o) (member o runtime :test #'equal))
                                      *sbcl-script-runtime-options*)
                           (list "--eval" form)
                           args)))
          ((and entry (> (length args) (cdr entry)))
           (dotimes (i (1+ (cdr entry)))
             (push (pop args) runtime)))
          (t
           (return (append (reverse runtime) (list "--eval" form) args))))))))

(defun lisp-startup (program form rest)
  "REST, the arguments of PROGRAM, with FORM evaluated at startup.
   Roswell starts with +Q: its default init loads Roswell's Quicklisp, which
   then answered for every system the project registry lacks, so a missing
   :depends-on loaded from the Quicklisp dist without a word (#166). A -Q in
   REST still turns Quicklisp on: Roswell's later option wins."
  (let ((name (pathname-name (uiop:parse-native-namestring program))))
    (cond
      ((string-equal name "ros") (append (list "+Q" "-e" form) rest))
      ((string-equal name "ecl") (append (list "-eval" form) rest))
      ((string-equal name "sbcl") (sbcl-startup form rest))
      ((member name '("ccl" "abcl") :test #'string-equal)
       (append (list "--eval" form) rest))
      (t rest))))

(defun run-startup-form (directory)
  "The form `cl-repo run` starts a lisp with: load ASDF, take cl-repo's fasl
   root (OUTPUT-TRANSLATIONS-FORM) and its fasl lock (FASL-LOCK-FORM, #162),
   and the project's source registry."
  (with-standard-io-syntax
    (format nil "(progn (require \"asdf\") ~s ~s (funcall (find-symbol \"INITIALIZE-SOURCE-REGISTRY\" \"ASDF\") '~s))"
            (output-translations-form)
            (fasl-lock-form)
            (namestrings (source-registry-form (project-registry-directories directory)
                                               :locked (locked-versions directory)
                                               :extra (explicit-source-registry-entries))))))

(defun cmd-run (argv &key (directory (uiop:getcwd)) system overlay)
  "Sync (SYSTEM, else every project system), then exec ARGV. A lisp
   implementation is started with the source registry already configured.
   CL_SOURCE_REGISTRY is not exported. The startup form loads ASDF itself and
   names it only through FIND-SYMBOL, so it reads and runs whatever options
   come before it (ros +Q starts without ASDF). For sbcl it follows the runtime
   options (SBCL-STARTUP). The sync's own messages go to stderr: stdout is the
   command's, for stdio servers (ACP, MCP) started this way (#130)."
  (when (null argv)
    (error "cl-repo: run requires a command"))
  (let ((*standard-output* *error-output*))
    (cmd-sync :directory directory :system system :overlay overlay))
  (let* ((form (run-startup-form directory))
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
