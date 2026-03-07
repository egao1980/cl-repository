(defpackage :cl-repository-client/commands
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:make-registry #:parse-reference #:registry)
  (:import-from :cl-oci-client/pull #:pull-manifest)
  (:import-from :cl-oci-client/content-discovery #:list-tags-paginated)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests #:image-index-annotations)
  (:import-from :cl-oci/annotations #:+ann-title+ #:+ann-version+ #:+ann-description+)
  (:import-from :cl-repository-client/installer #:install-system #:systems-root)
  (:import-from :cl-repository-client/lockfile #:read-lockfile #:lockfile-entry-system
                #:lockfile-entry-version #:lockfile-entry-registry)
  (:import-from :cl-repository-client/asdf-integration #:configure-asdf-source-registry)
  (:export #:cmd-install
           #:cmd-list
           #:cmd-search
           #:cmd-info
           #:cmd-update))
(in-package :cl-repository-client/commands)

(defvar *default-registry* "ghcr.io"
  "Default OCI registry URL.")

(defvar *default-namespace* "cl-systems"
  "Default repository namespace.")

(defun cmd-install (reference &key registry-url namespace)
  "Install a CL system. REFERENCE can be 'name', 'name:version', or 'registry/ns/name:ver'."
  (multiple-value-bind (host repo tag) (parse-reference reference)
    (let* ((reg-url (or host registry-url *default-registry*))
           (full-repo (if host repo
                         (format nil "~a/~a" (or namespace *default-namespace*) repo))))
      (install-system reg-url full-repo tag)
      (unless *dry-run*
        (configure-asdf-source-registry)))))

(defun cmd-list ()
  "List all installed systems."
  (let ((root (systems-root)))
    (if (probe-file root)
        (dolist (system-dir (uiop:subdirectories root))
          (let ((name (car (last (pathname-directory system-dir)))))
            (dolist (version-dir (uiop:subdirectories system-dir))
              (let ((ver (car (last (pathname-directory version-dir)))))
                (msg "~&~a ~a~%" name ver)))))
        (msg "~&No systems installed.~%"))))

(defun cmd-search (query &key registry-url namespace)
  "Search for systems by listing tags matching a query."
  (let* ((reg-url (or registry-url *default-registry*))
         (ns (or namespace *default-namespace*))
         (repo (format nil "~a/~a" ns query))
         (reg (make-registry reg-url)))
    (handler-case
        (let ((tags (list-tags-paginated reg repo)))
          (if tags
              (dolist (tag tags)
                (msg "~&~a:~a~%" query tag))
              (msg "~&No tags found for ~a~%" query)))
      (error (e)
        (msg "~&Search failed: ~a~%" e)))))

(defun cmd-info (reference &key registry-url namespace)
  "Show metadata for a system in the registry."
  (multiple-value-bind (host repo tag) (parse-reference reference)
    (let* ((reg-url (or host registry-url *default-registry*))
           (full-repo (if host repo
                         (format nil "~a/~a" (or namespace *default-namespace*) repo)))
           (reg (make-registry reg-url)))
      (handler-case
          (let ((obj (pull-manifest reg full-repo tag)))
            (etypecase obj
              (image-index
               (msg "~&Image Index for ~a:~a~%" full-repo tag)
               (msg "  Manifests: ~d~%" (length (image-index-manifests obj)))
               (let ((ann (image-index-annotations obj)))
                 (when (plusp (hash-table-count ann))
                   (maphash (lambda (k v) (msg "  ~a: ~a~%" k v)) ann))))))
        (error (e)
          (msg "~&Info failed: ~a~%" e))))))

(defun cmd-update (&key registry-url namespace)
  "Update all installed systems to latest versions."
  (let ((entries (read-lockfile)))
    (if entries
        (dolist (entry entries)
          (msg "~&Updating ~a...~%" (lockfile-entry-system entry))
          (handler-case
              (cmd-install (format nil "~a:latest" (lockfile-entry-system entry))
                           :registry-url (or registry-url (lockfile-entry-registry entry))
                           :namespace namespace)
            (error (e)
              (msg "  Failed: ~a~%" e))))
        (msg "~&No lockfile found. Nothing to update.~%"))))
