(defpackage :cl-repository-client/asdf-integration
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:export #:configure-asdf-source-registry
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
                 ((registry-mentions-p current root) current)
                 ((and (listp current) (eq (first current) :source-registry))
                  `(:source-registry (:tree ,root-str) ,@(rest current)))
                 (t
                  `(:source-registry (:tree ,root-str) :inherit-configuration)))))
        (asdf:initialize-source-registry new-config)))))

(defun load-system-init-files ()
  "Deprecated no-op, kept for one release for callers' scripts.
   cl-repo no longer writes or loads cl-repo-init.lisp: a package that ships
   native libraries loads them itself at ASDF load (absolute paths from its
   native/ directory), so (asdf:load-system \"foo\") is all a consumer needs."
  nil)
