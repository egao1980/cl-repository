(defpackage :cl-repository-client/asdf-integration
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version)
  (:import-from :cl-repository-client/client-tree
                #:client-tree-copies #:uninstall-client-tree-search)
  (:export #:configure-asdf-source-registry
           #:preferred-install-trees
           #:own-install-copies
           #:*own-copies*
           #:refresh-own-copies
           #:own-copy-search
           #:registry-search
           #:own-copies-form
           #:*locked-versions*
           #:load-system-init-files
           #:output-translations-form
           #:fasl-lock-form))
(in-package :cl-repository-client/asdf-integration)

(defun registry-mentions-p (parameter directory)
  "True when the :source-registry form PARAMETER has a :tree or :directory entry
   for DIRECTORY."
  (and (consp parameter)
       (eq (first parameter) :source-registry)
       (some (lambda (entry)
               (and (consp entry)
                    (member (first entry) '(:tree :directory))
                    (typep (second entry) (quote (or string pathname)))
                    (uiop:pathname-equal (uiop:ensure-directory-pathname (second entry))
                                         (uiop:ensure-directory-pathname directory))))
             (rest parameter))))

(defun output-translations-form ()
  "A form, readable before ASDF or UIOP is loaded (it names them only through
   FIND-SYMBOL), that gives the image cl-repo's own fasl root:
   <XDG_CACHE_HOME>/common-lisp/cl-repo/<implementation>/. cl-repo images
   run without Quicklisp; fasls compiled where Quicklisp was loaded
   (#+quicklisp code, rove) broke them through the shared ~/.cache/common-lisp
   (#121). An image that has Quicklisp, or that ASDF_OUTPUT_TRANSLATIONS
   configures, keeps ASDF's default. roswell/cl-repo.ros and the ci action's
   run.lisp inline the same form for the client image."
  '(unless (or (member :quicklisp *features*)
               (funcall (find-symbol "GETENVP" "UIOP") "ASDF_OUTPUT_TRANSLATIONS"))
     (funcall (find-symbol "INITIALIZE-OUTPUT-TRANSLATIONS" "ASDF")
              (list :output-translations
                    (list t (list (funcall (find-symbol "XDG-CACHE-HOME" "UIOP")
                                           "common-lisp" "cl-repo" :implementation)
                                  :**/ :*.*.*))
                    :inherit-configuration))))

(defun fasl-lock-source ()
  "roswell/fasl-lock.lisp of the cl-repository-client this image runs, or NIL.
   REGISTERED-SYSTEM, not FIND-SYSTEM: no search, so no pin check."
  (let ((system (asdf:registered-system "cl-repository-client")))
    (and system
         (asdf:system-source-directory system)
         (probe-file (merge-pathnames "roswell/fasl-lock.lisp"
                                      (asdf:system-source-directory system))))))

(defun fasl-lock-form ()
  "A form, readable before ASDF is loaded and run once it is, that loads
   roswell/fasl-lock.lisp into the image: its compiles and loads of the shared
   fasl root then hold a lock per fasl, so parallel cl-repo images do not
   delete each other's fasls mid-load (#162). NIL when this client has no
   such file."
  (let ((file (fasl-lock-source)))
    (when file
      `(unless (find-package "CL-REPO-FASL-LOCK")
         (load ,(namestring file) :verbose nil :print nil)))))

(defvar *locked-versions* nil
  "Alist system → version from the project's cl-repo.lock (REGISTER-PROJECT
   sets it); PREFERRED-INSTALL-TREES prefers these versions.")

(defun dir-leaf (dir)
  (car (last (pathname-directory dir))))

(defun preferred-install-trees (root &optional locked)
  "A (:tree DIR) per installed system under ROOT with several versions: the
   version LOCKED (alist system → version) names, else the newest. ASDF takes
   the first .asd it meets in a :tree, in path order, so an installed 0.2.0
   would shadow 0.2.2 (mime-protocol then failed on serdes-protocol 0.2.0)."
  (loop for sys-dir in (ignore-errors (uiop:subdirectories root))
        for versions = (mapcar #'dir-leaf (uiop:subdirectories sys-dir))
        when (cdr versions)
          collect (let* ((locked-version (cdr (assoc (dir-leaf sys-dir) locked :test #'string-equal)))
                         (want (if (member locked-version versions :test #'equal)
                                   locked-version
                                   (select-preferred-version versions))))
                    (list :tree (namestring (merge-pathnames (format nil "~a/" want) sys-dir))))))

;;; Bundled .asd files (#199). An image packed from a multi-system repo
;;; carries every .asd of that repo, so an old sql-backend-postgres:0.1.0
;;; install also holds sql-protocol.asd 0.1.0. ASDF takes the first .asd a
;;; :tree scan meets, and a source-registry form selects directories, not
;;; files, so no entry order can prefer sql-protocol/0.2.0/sql-protocol.asd
;;; for one system and keep the bundled sibling .asd files for the others
;;; (babel-tests.asd lives only in babel/). A search function before the
;;; source registry maps exactly the systems that resolve into another
;;; install directory back to their own install.

(defun own-install-file (name sys-dir locked)
  "NAME.asd in the version of SYS-DIR (NAME's install directory) that LOCKED
   names, else the newest. NIL when that version has no NAME.asd."
  (let* ((versions (mapcar #'dir-leaf (uiop:subdirectories sys-dir)))
         (locked-version (cdr (assoc name locked :test #'string-equal)))
         (want (if (member locked-version versions :test #'equal)
                   locked-version
                   (and versions (select-preferred-version versions)))))
    (and want (probe-file (merge-pathnames (format nil "~a/~a.asd" want name) sys-dir)))))

(defun own-install-copies (root &optional locked)
  "Alist primary system name → namestring of its own installed .asd, for each
   system under ROOT that the current source registry resolves to a .asd
   inside another install directory. A system resolved outside ROOT (the
   project checkout, CL_SOURCE_REGISTRY trees) is left alone: those shadow
   installed copies on purpose."
  (let ((root-true (uiop:truename* root)))
    (when root-true
      (loop for sys-dir in (uiop:subdirectories root-true)
            for name = (dir-leaf sys-dir)
            for found = (asdf/source-registry:sysdef-source-registry-search name)
            for found-true = (and found (uiop:truename* found))
            for own = (and found-true
                           (uiop:subpathp found-true root-true)
                           (not (uiop:subpathp found-true sys-dir))
                           (own-install-file name sys-dir locked))
            when (and own (not (redundant-copy-p found-true own)))
              collect (cons name (namestring own))))))

(defun %file-octets (file)
  (with-open-file (in file :element-type '(unsigned-byte 8))
    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence v in)
      v)))

(defun redundant-copy-p (found own)
  "True when loading FOUND instead of OWN changes nothing: the .asd files are
   byte-identical and OWN's install has no native/ overlay (natives install
   into the system's own directory, not into the bundles). Such entries are
   dropped from *OWN-COPIES*, which a fresh image gets on its command line
   (#212: ~500 installs made it ~12 KB, a third of Windows' limit)."
  (and (not (probe-file (merge-pathnames "native/" (uiop:pathname-directory-pathname own))))
       (equalp (%file-octets found) (%file-octets own))))

(defvar *own-copies* '()
  "OWN-INSTALL-COPIES of the current source registry (REFRESH-OWN-COPIES).")

(defun own-copy-search (name)
  "ASDF search function: the own install of NAME's primary system when
   *OWN-COPIES* has one, else NIL (the source registry decides)."
  (let ((file (cdr (assoc (asdf:primary-system-name name) *own-copies* :test #'string=))))
    (and file (probe-file file))))

(defun registry-search (name)
  "The .asd a fresh image with the current registry loads for NAME:
   SYSDEF-SOURCE-REGISTRY-SEARCH with *OWN-COPIES* applied."
  (or (own-copy-search name)
      (asdf/source-registry:sysdef-source-registry-search name)))

(defun running-client-directories ()
  "The running client's own directories (CL_REPOSITORY_CLIENT_DIR, the
   source directory of cl-repository-client): CLIENT-TREE-COPIES leaves what
   they provide alone, so the client's systems stay one release."
  (remove-duplicates
   (remove nil
           (list (uiop:getenv-absolute-directory "CL_REPOSITORY_CLIENT_DIR")
                 (let ((system (asdf:registered-system "cl-repository-client")))
                   (and system (asdf:system-source-directory system)))))
   :test #'uiop:pathname-equal))

(defun default-client-tree ()
  "The client tree, CL_REPOSITORY_DEST (NAME-VERSION directories), or NIL."
  (uiop:getenv-absolute-directory "CL_REPOSITORY_DEST"))

(defun refresh-own-copies (&optional (root (systems-root)) (locked *locked-versions*)
                                     (client-tree (default-client-tree)))
  "Recompute *OWN-COPIES* for the current source registry and put
   OWN-COPY-SEARCH first among ASDF's search functions. Call after every
   INITIALIZE-SOURCE-REGISTRY. *OWN-COPIES* maps the install tree under ROOT
   (OWN-INSTALL-COPIES) and the client tree CLIENT-TREE (CLIENT-TREE-COPIES,
   newest release; cl-repository#207). The launcher's own client tree
   mapping (INSTALL-CLIENT-TREE-SEARCH) is dropped: it was computed for the
   launcher's registry, not this one."
  (uninstall-client-tree-search)
  (setf *own-copies*
        (append (and (probe-file root) (own-install-copies root locked))
                (and client-tree
                     (not (uiop:pathname-equal (uiop:ensure-directory-pathname client-tree)
                                               (uiop:ensure-directory-pathname root)))
                     (client-tree-copies client-tree :keep (running-client-directories)))))
  (setf asdf:*system-definition-search-functions*
        (cons 'own-copy-search
              (remove 'own-copy-search asdf:*system-definition-search-functions*)))
  *own-copies*)

(defun own-copies-form ()
  "A form string, readable before ASDF is loaded (it names ASDF only through
   FIND-SYMBOL), that gives a fresh image the same own-install mapping as
   *OWN-COPIES*. NIL when there is nothing to map. Printed without
   *PRINT-READABLY*: SBCL base-strings print as #A(...) otherwise (#190)."
  (when *own-copies*
    (with-standard-io-syntax
      (let ((*print-readably* nil))
        (format nil "(let ((s (find-symbol \"*SYSTEM-DEFINITION-SEARCH-FUNCTIONS*\" \"ASDF\")) (table (quote ~S))) (setf (symbol-value s) (cons (lambda (name) (let ((file (cdr (assoc (funcall (find-symbol \"PRIMARY-SYSTEM-NAME\" \"ASDF\") name) table :test (function string=))))) (and file (probe-file file)))) (symbol-value s))))"
                *own-copies*)))))

(defun under-root-tree-p (entry root)
  "ENTRY is a (:tree DIR) strictly inside ROOT: a preference entry."
  (and (consp entry) (eq (first entry) :tree)
       (typep (second entry) '(or string pathname))
       (let ((dir (uiop:ensure-directory-pathname (second entry))))
         (and (uiop:subpathp dir root) (not (uiop:pathname-equal dir root))))))

(defun with-fresh-preferences (form root)
  "FORM with the preference entries before ROOT's :tree recomputed: a version
   installed since FORM was built must win over an older one too."
  (let ((root (uiop:ensure-directory-pathname root)))
    `(:source-registry
      ,@(loop for entry in (rest form)
              unless (under-root-tree-p entry root)
                if (and (consp entry) (member (first entry) '(:tree :directory))
                        (typep (second entry) '(or string pathname))
                        (uiop:pathname-equal (uiop:ensure-directory-pathname (second entry)) root))
                  append (append (preferred-install-trees root *locked-versions*) (list entry))
                else collect entry))))

(defun configure-asdf-source-registry ()
  "Put the cl-repository systems directory on the ASDF source registry and
   re-scan it, so systems installed since the last scan are found.
   Preserves existing programmatic configuration (e.g. Quicklisp paths).
   ASDF scans a :tree once, at INITIALIZE-SOURCE-REGISTRY, so this must
   re-initialize even when the tree is already registered (0.27.1 stopped
   doing that and lost every system a sync installed: \"rove is not in the
   registry\")."
  (let ((root (systems-root)))
    (when (probe-file root)
      (let* ((root-str (namestring root))
             (current asdf/source-registry:*source-registry-parameter*)
             (new-config
               (cond
                 ;; Already registered (register-project put it after the
                 ;; checkout): keep the order — prepending would shadow the
                 ;; system under test with an older installed copy — but
                 ;; re-scan.
                 ((registry-mentions-p current root) (with-fresh-preferences current root))
                 ((and (listp current) (eq (first current) :source-registry))
                  `(:source-registry ,@(preferred-install-trees root *locked-versions*)
                                     (:tree ,root-str) ,@(rest current)))
                 (t
                  `(:source-registry ,@(preferred-install-trees root *locked-versions*)
                                     (:tree ,root-str) :inherit-configuration)))))
        (asdf:initialize-source-registry new-config)
        (refresh-own-copies root)))))

(defun load-system-init-files ()
  "Deprecated no-op, kept for one release for callers' scripts.
   cl-repo no longer writes or loads cl-repo-init.lisp: a package that ships
   native libraries loads them itself at ASDF load (absolute paths from its
   native/ directory), so (asdf:load-system \"foo\") is all a consumer needs."
  nil)
