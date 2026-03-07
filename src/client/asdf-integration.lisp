(defpackage :cl-repository-client/asdf-integration
  (:use :cl)
  (:import-from :cl-repository-client/installer #:systems-root)
  (:export #:configure-asdf-source-registry
           #:load-system-init-files))
(in-package :cl-repository-client/asdf-integration)

(defun configure-asdf-source-registry ()
  "Register the cl-repository systems directory with ASDF source registry.
   Clears the cache first so newly installed systems are discoverable."
  (let ((root (systems-root)))
    (when (probe-file root)
      (asdf:clear-source-registry)
      (asdf:initialize-source-registry
       `(:source-registry
         (:tree ,(namestring root))
         :inherit-configuration)))))

(defun load-system-init-files ()
  "Load cl-repo-init.lisp files from all installed systems for CFFI setup."
  (let ((root (systems-root)))
    (when (probe-file root)
      (dolist (system-dir (uiop:subdirectories root))
        (dolist (version-dir (uiop:subdirectories system-dir))
          (let ((init-file (merge-pathnames "cl-repo-init.lisp" version-dir)))
            (when (probe-file init-file)
              (load init-file))))))))
