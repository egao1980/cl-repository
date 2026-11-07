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

(defun %dependency-closure (systems)
  "Primary names of SYSTEMS and everything they depend on, as ASDF resolves
   them. Only .asd files are read; no system is loaded."
  (let ((seen (make-hash-table :test #'equal)) (out '()))
    (labels ((dep-name (dep)
               (cond ((stringp dep) dep)
                     ((symbolp dep) (string-downcase (symbol-name dep)))
                     ;; (:version "x" "1.0"), (:feature f "x"), (:require "x")
                     ((and (consp dep) (member (first dep) '(:version :feature)))
                      (dep-name (if (eq (first dep) :version) (second dep) (third dep))))
                     (t nil)))
             (walk (name)
               (let ((name (and name (string-downcase name))))
                 (when (and name (not (gethash name seen)))
                   (setf (gethash name seen) t)
                   (let ((sys (asdf:find-system name nil)))
                     (when sys
                       (push (asdf:primary-system-name sys) out)
                       (dolist (d (append (asdf:system-depends-on sys)
                                          (asdf:system-defsystem-depends-on sys)))
                         (walk (dep-name d)))))))))
      (mapc #'walk systems))
    (remove-duplicates out :test #'string=)))

(defun load-system-init-files (&key systems)
  "Load cl-repo-init.lisp files for CFFI setup (they preload bundled natives).
   With SYSTEMS, only the installed copies ASDF resolves for SYSTEMS and their
   dependency closure; without, every installed system (the old behaviour).
   Loading every system in a shared store preloads natives of unrelated
   projects — on a developer machine that can be a library whose static
   initialisers abort the process."
  (let ((root (systems-root)))
    (when (probe-file root)
      (if systems
          (let ((root-dir (namestring (truename root))))
            (dolist (name (%dependency-closure systems))
              (let* ((sys (asdf:find-system name nil))
                     (dir (and sys (asdf:system-source-directory sys)))
                     (init (and dir (merge-pathnames "cl-repo-init.lisp" dir))))
                (when (and init (probe-file init)
                           (uiop:string-prefix-p root-dir (namestring (truename dir))))
                  (load init)))))
          (dolist (system-dir (uiop:subdirectories root))
            (dolist (version-dir (uiop:subdirectories system-dir))
              (let ((init-file (merge-pathnames "cl-repo-init.lisp" version-dir)))
                (when (probe-file init-file)
                  (load init-file)))))))))
