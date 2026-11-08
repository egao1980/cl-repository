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
  "Prepend the cl-repository systems directory to the ASDF source registry.
   Preserves existing programmatic configuration (e.g. Quicklisp paths)."
  (let ((root (systems-root)))
    (when (and (probe-file root)
               ;; Already on the registry (register-project put it there, after
               ;; the checkout): prepending again would shadow the system under
               ;; test with an older installed copy of itself.
               (not (registry-mentions-p asdf/source-registry:*source-registry-parameter* root)))
      (let* ((root-str (namestring root))
             (current asdf/source-registry:*source-registry-parameter*)
             (new-config
               (if (and (listp current)
                        (eq (first current) :source-registry))
                   ;; Prepend our tree to existing config entries
                   `(:source-registry
                     (:tree ,root-str)
                     ,@(rest current))
                   ;; No prior programmatic config — inherit defaults
                   `(:source-registry
                     (:tree ,root-str)
                     :inherit-configuration))))
        (asdf:initialize-source-registry new-config)))))

(defun load-system-init-files ()
  "Deprecated no-op, kept for one release for callers' scripts.
   cl-repo no longer writes or loads cl-repo-init.lisp: a package that ships
   native libraries loads them itself at ASDF load (absolute paths from its
   native/ directory), so (asdf:load-system \"foo\") is all a consumer needs."
  nil)
