(defpackage :cl-repository-client/project
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:msg)
  (:import-from :cl-repository-client/commands
                #:cmd-install #:cmd-restore
                #:*default-registry* #:*default-namespace*)
  (:import-from :cl-repository-client/quickload
                #:add-registry #:ensure-system-dependencies)
  (:import-from :cl-repository-client/asdf-integration
                #:configure-asdf-source-registry #:load-system-init-files)
  (:import-from :cl-repository-client/installer #:systems-root #:*requested-overlay*)
  (:import-from :cl-repository-client/qlot-integration
                #:read-qlfile #:read-qlfile-lock
                #:qlot-entry-kind #:qlot-entry-name #:qlot-entry-ref)
  (:import-from :cl-repository-client/platform-resolver
                #:choose-overlay-plists #:detect-local-platform #:overlay-key)
  (:import-from :cl-repository-client/asd-rewrite #:read-system-overlays)
  (:export #:client-source-tree
           #:ensure-default-registry
           #:register-project
           #:discover-project-system
           #:expand-ci-env
           #:cmd-sync
           #:cmd-test
           #:cmd-run
           #:cmd-grovel
           #:*default-ql-dist*))
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

(defun source-registry-form (directories)
  `(:source-registry
    ,@(mapcar (lambda (dir)
                (list :tree (namestring (uiop:ensure-directory-pathname dir))))
              directories)
    :ignore-inherited-configuration))

(defun register-project (directory)
  "Register the project, the installed systems, and the client tree.
   Does not export CL_SOURCE_REGISTRY and does not inherit it."
  (let ((dirs (remove-if #'null
                         (list directory
                               (let ((root (systems-root)))
                                 (when (probe-file root) root))
                               (ignore-errors (client-source-tree))))))
    (asdf:initialize-source-registry (source-registry-form dirs))))

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
           (asdf:load-system "cl-repository-packager")
           (asdf:load-system "cl-repository-ql-exporter"))
      (when saved
        (asdf:initialize-source-registry saved)))))

(defun publish-ql-system (name dist-url)
  (ensure-publish-tools)
  (uiop:symbol-call :cl-repository-ql-exporter/exporter :export-dist
                    dist-url *default-registry*
                    :namespace *default-namespace*
                    :filter name
                    :incremental t))

(defun publish-source-dir (source-dir &key source-url revision ref)
  (ensure-publish-tools)
  (multiple-value-bind (spec result)
      (uiop:symbol-call :cl-repository-packager/source-adapter :build-package-from-source
                        source-dir :source-url source-url :revision revision :version ref)
    (let ((tag (or (funcall (find-symbol "PACKAGE-SPEC-VERSION"
                                         :cl-repository-packager/build-matrix)
                            spec)
                   ref
                   "latest")))
      (uiop:symbol-call :cl-repository-packager/publisher :publish-package
                        *default-registry* *default-namespace* tag result spec)
      (funcall (find-symbol "PACKAGE-SPEC-NAME" :cl-repository-packager/build-matrix) spec))))

(defun install-or-publish (reference publish)
  "Install REFERENCE. When that fails, call PUBLISH and install the bare name."
  (handler-case
      (progn (cmd-install reference :registry-url *default-registry*
                          :namespace *default-namespace*)
             t)
    (error ()
      (funcall publish)
      (let ((name (subseq reference 0 (or (position #\: reference) (length reference)))))
        (cmd-install name :registry-url *default-registry* :namespace *default-namespace*)))))

(defun repo-system-name (repo)
  (let ((slash (position #\/ repo :from-end t)))
    (if slash (subseq repo (1+ slash)) repo)))

(defun sync-github-entry (entry directory)
  (declare (ignore directory))
  (let* ((repo (qlot-entry-name entry))
         (ref (qlot-entry-ref entry))
         (system (repo-system-name repo))
         (reference (if ref (format nil "~a:~a" system ref) system)))
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
            (ref (qlot-entry-ref entry))
            (reference (if (and ref (not (string-equal ref "latest")))
                           (format nil "~a:~a" name ref)
                           name)))
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

(defun cmd-sync (&key (directory (uiop:getcwd)) system overlay locked)
  "Install what the .asd and qlfile ask for, and record the lock.
   OVERLAY names an opt-in overlay such as cuda, installed on top of the automatic stack.
   LOCKED installs cl-repo.lock."
  (let ((dir (uiop:ensure-directory-pathname directory))
        (*requested-overlay* (overlay-request overlay)))
    (when (member (namestring dir) *sync-stack* :test #'equal)
      (return-from cmd-sync nil))
    (let ((*sync-stack* (cons (namestring dir) *sync-stack*)))
      (ensure-default-registry)
      (register-project dir)
      (clear-project-systems dir)
      (if locked
          (cmd-restore :registry-url *default-registry* :namespace *default-namespace*)
          (progn
            (sync-qlfile dir)
            (register-project dir)
            (let ((name (or system (discover-project-system dir))))
              (when name
                (asdf:find-system name nil)
                (multiple-value-bind (env-install env-load)
                    (expand-ci-env (getf (ci-plist name) :env))
                  (declare (ignore env-load))
                  (ensure-system-dependencies
                   name
                   :with (append (project-with name) env-install)
                   :also-tests (getf (ci-plist name) :also-tests t))))))))))

(defun cmd-test (&key (directory (uiop:getcwd)) system overlay (sync t))
  "Sync, then asdf:test-system. A system with no test-op still exits 0."
  (when sync
    (cmd-sync :directory directory :system system :overlay overlay))
  (let ((name (or system (discover-project-system directory))))
    (unless name
      (error "cl-repo: no system to test in ~a" directory))
    (register-project directory)
    (configure-asdf-source-registry)
    (load-system-init-files)
    (multiple-value-bind (env-install env-load)
        (expand-ci-env (getf (ci-plist name) :env))
      (declare (ignore env-install))
      (dolist (extra (append (project-load-before-test name) env-load))
        (asdf:load-system extra)))
    (asdf:load-system name)
    (asdf:test-system name)))

(defun lisp-startup (program form rest)
  (cond
    ((string-equal program "ros") (append (list "-e" form) rest))
    ((string-equal program "ecl") (append (list "-eval" form) rest))
    ((member program '("sbcl" "ccl" "abcl") :test #'string-equal)
     (append (list "--eval" form) rest))
    (t rest)))

(defun cmd-run (argv &key (directory (uiop:getcwd)) overlay)
  "Sync, then exec ARGV. A lisp implementation is started with the source
   registry already configured. CL_SOURCE_REGISTRY is not exported."
  (when (null argv)
    (error "cl-repo: run requires a command"))
  (cmd-sync :directory directory :overlay overlay)
  (let* ((form (format nil "(asdf:initialize-source-registry '~s)"
                       (source-registry-form
                        (remove nil (list directory (systems-root) (ignore-errors (client-source-tree)))))))
         (args (lisp-startup (first argv) form (rest argv)))
         (code (nth-value 2 (uiop:run-program (cons (first argv) args)
                                              :ignore-error-status t
                                              :output :interactive
                                              :error-output :interactive
                                              :input :interactive))))
    (unless (zerop code)
      (uiop:quit code))))

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
   most specific matching overlay is created for the output."
  (cmd-sync :directory directory :system system :overlay overlay)
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (name (or system (discover-project-system dir)))
         (key (machine-overlay-key dir))
         (out (merge-pathnames (format nil "grovel/~a/" key) dir)))
    (ensure-directories-exist (merge-pathnames ".keep" out))
    (when name
      (asdf:load-system name))
    out))
