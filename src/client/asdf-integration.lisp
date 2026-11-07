(defpackage :cl-repository-client/asdf-integration
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:export #:configure-asdf-source-registry
           #:load-system-init-files))
(in-package :cl-repository-client/asdf-integration)

(defun configure-asdf-source-registry ()
  "Prepend the cl-repository systems directory to the ASDF source registry.
   Preserves existing programmatic configuration (e.g. Quicklisp paths)."
  (let ((root (systems-root)))
    (when (probe-file root)
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
