(defpackage :cl-repository-client/asdf-integration
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version)
  (:export #:configure-asdf-source-registry
           #:preferred-install-trees
           #:*locked-versions*
           #:load-system-init-files))
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
