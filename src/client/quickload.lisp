(defpackage :cl-repository-client/quickload
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:make-registry)
  (:import-from :cl-oci-client/content-discovery #:list-tags)
  (:import-from :cl-repository-client/installer #:install-system #:systems-root #:system-install-path)
  (:import-from :cl-repository-client/asdf-integration #:configure-asdf-source-registry)
  (:export #:*registries*
           #:add-registry
           #:load-system))
(in-package :cl-repository-client/quickload)

(defvar *registries* nil
  "Ordered list of OCI registries to search.
   Each entry is (URL &key namespace).
   Example:
     ((\"http://localhost:5050\" :namespace \"cl-systems\")
      (\"https://ghcr.io\" :namespace \"cl-systems\"))")

(defun add-registry (url &key (namespace "cl-systems") (priority :append))
  "Add a registry to *registries*.
   PRIORITY is :prepend (search first) or :append (search last).
   Avoids duplicates by URL."
  (let ((entry (list url :namespace namespace)))
    (unless (find url *registries* :key #'first :test #'string=)
      (ecase priority
        (:prepend (push entry *registries*))
        (:append (setf *registries* (append *registries* (list entry)))))))
  *registries*)

(defun registry-url (entry) (first entry))
(defun registry-namespace (entry) (getf (rest entry) :namespace "cl-systems"))

(defun system-already-installed-p (name)
  "Check if any version of NAME is installed locally."
  (let ((dir (merge-pathnames (format nil "~a/" name) (systems-root))))
    (and (probe-file dir)
         (uiop:subdirectories dir))))

(defun find-system-in-registry (reg-url namespace system-name)
  "Try to find SYSTEM-NAME in a registry. Returns (values repo latest-tag) or NIL."
  (let* ((repo (format nil "~a/~a" namespace system-name))
         (reg (make-registry reg-url)))
    (handler-case
        (let ((tags (list-tags reg repo)))
          (when tags
            (values repo (first (last tags)))))
      (error () nil))))

(defun ensure-system-installed (name &key version)
  "Ensure NAME is installed from one of *registries*. Returns install path or NIL.
   When VERSION is given, uses it directly. Otherwise discovers the latest tag."
  (dolist (entry *registries* nil)
    (let ((url (registry-url entry))
          (ns (registry-namespace entry)))
      (handler-case
          (multiple-value-bind (repo tag)
              (if version
                  (values (format nil "~a/~a" ns name) version)
                  (find-system-in-registry url ns name))
            (when (and repo tag)
              (msg "~&; cl-repo: found ~a:~a in ~a~%" name tag url)
              (return-from ensure-system-installed (install-system url repo tag))))
        (error (e)
          (msg "~&; cl-repo: ~a not in ~a (~a)~%" name url e))))))

(defun load-system (systems &key silent version)
  "Install (if needed) and load Common Lisp systems from OCI registries.
   SYSTEMS is a system name (string/symbol), or a list of them.
   SILENT suppresses output. VERSION pins a specific tag (applies to all systems).

   Usage:
     (cl-repo:load-system \"alexandria\")
     (cl-repo:load-system '(\"alexandria\" \"cl-ppcre\") :silent t)
     (cl-repo:load-system \"split-sequence\" :version \"sequence-v2.0.1\")"
  (let* ((*quiet* (or *quiet* silent))
         (system-list (if (listp systems) systems (list systems)))
         (installed-any nil))
    (dolist (sys system-list)
      (let ((name (string-downcase (string sys))))
        (unless (asdf:find-system name nil)
          (unless (system-already-installed-p name)
            (let ((path (ensure-system-installed name :version version)))
              (if path
                  (setf installed-any t)
                  (msg "~&; cl-repo: ~a not found in any registry~%" name)))))))
    (when installed-any
      (configure-asdf-source-registry))
    (dolist (sys system-list)
      (let ((name (string-downcase (string sys))))
        (msg "~&; cl-repo: loading ~a~%" name)
        (handler-case (asdf:load-system name)
          (error (e)
            (msg "~&; cl-repo: failed to load ~a: ~a~%" name e)))))
    (if (= (length system-list) 1)
        (first system-list)
        system-list)))
