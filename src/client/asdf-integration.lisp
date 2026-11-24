(defpackage :cl-repository-client/asdf-integration
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version)
  (:export #:configure-asdf-source-registry
           #:preferred-install-trees
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
        (asdf:initialize-source-registry new-config)))))

(defun load-system-init-files ()
  "Deprecated no-op, kept for one release for callers' scripts.
   cl-repo no longer writes or loads cl-repo-init.lisp: a package that ships
   native libraries loads them itself at ASDF load (absolute paths from its
   native/ directory), so (asdf:load-system \"foo\") is all a consumer needs."
  nil)
