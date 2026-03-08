(defpackage :cl-repository-client/commands
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:make-registry #:parse-reference #:registry
                #:registry-request)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-manifest-raw)
  (:import-from :cl-oci-client/content-discovery #:list-tags-paginated #:list-referrers)
  (:import-from :cl-oci-client/conditions #:registry-error)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests #:image-index-annotations)
  (:import-from :cl-oci/descriptor #:descriptor-annotations #:descriptor-artifact-type)
  (:import-from :cl-oci/annotations #:+ann-title+ #:+ann-version+ #:+ann-description+
                #:+cl-system-name+ #:+cl-provides+)
  (:import-from :cl-oci/media-types #:+cl-system-name-anchor-v1+ #:+oci-image-manifest-v1+)
  (:import-from :cl-repository-client/installer #:install-system #:install-result-path #:systems-root)
  (:import-from :cl-oci/digest #:format-digest #:compute-digest)
  (:import-from :cl-repository-client/lockfile #:lockfile-entry #:read-lockfile #:write-lockfile
                #:lockfile-entry-system #:lockfile-entry-version #:lockfile-entry-registry)
  (:import-from :cl-repository-client/constraint-builder #:scan-installed-systems)
  (:import-from :cl-repository-client/asdf-integration #:configure-asdf-source-registry)
  (:import-from :cl-repository-client/quickload #:*registries*)
  (:export #:cmd-install
           #:cmd-list
           #:cmd-search
           #:cmd-info
           #:cmd-update
           #:cmd-lock
           #:cmd-restore))
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

(defun cmd-list (&key remote)
  "List systems. Without REMOTE, lists locally installed. With REMOTE, queries ns-catalog referrers."
  (if remote
      (cmd-list-remote)
      (cmd-list-local)))

(defun cmd-list-local ()
  (let ((root (systems-root)))
    (if (probe-file root)
        (dolist (system-dir (uiop:subdirectories root))
          (let ((name (car (last (pathname-directory system-dir)))))
            ;; Detect symlinks
            (let ((is-link (not (equal (namestring system-dir)
                                       (namestring (truename system-dir))))))
              (dolist (version-dir (uiop:subdirectories system-dir))
                (let ((ver (car (last (pathname-directory version-dir)))))
                  (if is-link
                      (msg "~&~a ~a (-> ~a)~%" name ver
                           (car (last (pathname-directory (truename system-dir)))))
                      (msg "~&~a ~a~%" name ver)))))))
        (msg "~&No systems installed.~%"))))

(defun cmd-list-remote ()
  "List all systems in configured registries via ns-catalog referrers."
  (dolist (entry *registries*)
    (let* ((url (first entry))
           (ns (getf (rest entry) :namespace "cl-systems"))
           (reg (make-registry url))
           (root-repo (format nil "~a/ns-catalog" ns)))
      (msg "~&Registry: ~a (~a)~%" url ns)
      (handler-case
          (let ((root-digest (head-manifest-digest reg root-repo "latest")))
            (if root-digest
                (let ((idx (list-referrers reg root-repo root-digest)))
                  (if idx
                      (dolist (desc (image-index-manifests idx))
                        (let ((ann (descriptor-annotations desc)))
                          (msg "~&  ~a ~a~%"
                               (gethash +cl-system-name+ ann "?")
                               (gethash +ann-version+ ann ""))))
                      (msg "~&  No systems published.~%")))
                (msg "~&  No root anchor found.~%")))
        (error (e)
          (msg "~&  Error: ~a~%" e))))))

(defun cmd-search (query &key registry-url namespace)
  "Search for systems. Queries ns-catalog referrers and filters by substring."
  (let ((found nil))
    (dolist (entry (or (when registry-url
                         (list (list registry-url :namespace (or namespace *default-namespace*))))
                       *registries*))
      (let* ((url (first entry))
             (ns (getf (rest entry) :namespace "cl-systems"))
             (reg (make-registry url))
             (root-repo (format nil "~a/ns-catalog" ns)))
        (handler-case
            (let ((root-digest (head-manifest-digest reg root-repo "latest")))
              (when root-digest
                (let ((idx (list-referrers reg root-repo root-digest)))
                  (when idx
                    (dolist (desc (image-index-manifests idx))
                      (let* ((ann (descriptor-annotations desc))
                             (name (gethash +cl-system-name+ ann))
                             (version (gethash +ann-version+ ann ""))
                             (provides (gethash +cl-provides+ ann ""))
                             (description (gethash +ann-description+ ann "")))
                        (when (and name
                                   (or (search query name :test #'char-equal)
                                       (search query provides :test #'char-equal)
                                       (search query description :test #'char-equal)))
                          (push t found)
                          (msg "~&~a ~a" name version)
                          (when (plusp (length provides))
                            (msg "  [provides: ~a]" provides))
                          (when (plusp (length description))
                            (msg "~%    ~a" description))
                          (msg "~%"))))))))
          (error () nil))))
    ;; Fallback: try direct tag listing
    (unless found
      (dolist (entry (or (when registry-url
                           (list (list registry-url :namespace (or namespace *default-namespace*))))
                         *registries*))
        (let* ((url (first entry))
               (ns (getf (rest entry) :namespace "cl-systems"))
               (repo (format nil "~a/~a" ns query))
               (reg (make-registry url)))
          (handler-case
              (let ((tags (list-tags-paginated reg repo)))
                (when tags
                  (dolist (tag tags)
                    (msg "~&~a:~a~%" query tag))
                  (setf found t)))
            (error () nil)))))
    (unless found
      (msg "~&No results for \"~a\"~%" query))))

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

(defun cmd-lock ()
  "Generate cl-repo.lock from installed systems.
   For each installed system, queries configured registries to obtain manifest digests."
  (let ((installed (scan-installed-systems))
        (existing (read-lockfile))
        (entries nil))
    (if (null installed)
        (msg "~&No systems installed. Nothing to lock.~%")
        (progn
          (dolist (pair installed)
            (let* ((name (car pair))
                   (version (cdr pair))
                   (prev (find name existing :key #'lockfile-entry-system :test #'string=)))
              (if (and prev (string= (lockfile-entry-version prev) version))
                  (push prev entries)
                  (let ((entry (resolve-lockfile-entry name version)))
                    (when entry (push entry entries))))))
          (setf entries (sort entries #'string< :key #'lockfile-entry-system))
          (write-lockfile entries)
          (msg "~&Wrote cl-repo.lock (~d systems)~%" (length entries))))))

(defun cmd-restore (&key registry-url namespace)
  "Install exact versions from cl-repo.lock for reproducible builds."
  (let ((entries (read-lockfile)))
    (if (null entries)
        (msg "~&No lockfile found. Run 'cl-repo lock' first.~%")
        (progn
          (msg "~&Restoring ~d systems from lockfile...~%" (length entries))
          (dolist (entry entries)
            (let* ((name (lockfile-entry-system entry))
                   (version (lockfile-entry-version entry))
                   (reg (or registry-url (lockfile-entry-registry entry)))
                   (ns (or namespace *default-namespace*))
                   (repo (format nil "~a/~a" ns name)))
              (msg "~&  ~a ~a~%" name version)
              (handler-case
                  (progn
                    (install-system reg repo version)
                    (configure-asdf-source-registry))
                (error (e)
                  (msg "~&  Failed to restore ~a ~a: ~a~%" name version e)))))
          (msg "~&Restore complete.~%")))))

(defun resolve-lockfile-entry (name version)
  "Try to resolve digest info for NAME at VERSION from configured registries.
   Returns a LOCKFILE-ENTRY or NIL."
  (dolist (reg-entry *registries*)
    (let* ((url (first reg-entry))
           (ns (getf (rest reg-entry) :namespace "cl-systems"))
           (repo (format nil "~a/~a" ns name))
           (reg (make-registry url)))
      (handler-case
          (multiple-value-bind (body status headers)
              (pull-manifest-raw reg repo version)
            (declare (ignore status))
            (let ((digest (or (gethash "docker-content-digest" headers)
                              (format-digest (compute-digest body)))))
              (return-from resolve-lockfile-entry
                (make-instance 'lockfile-entry
                               :system name
                               :version version
                               :index-digest digest
                               :registry url))))
        (error () nil))))
  ;; No registry had it — create entry without digest
  (msg "~&  Warning: ~a ~a not found in any registry, recording without digest~%" name version)
  (make-instance 'lockfile-entry
                 :system name
                 :version version
                 :index-digest ""
                 :registry ""))

;;; Helpers

(defun head-manifest-digest (registry repository reference)
  "HEAD a manifest and return its digest string."
  (handler-case
      (multiple-value-bind (body status headers)
          (registry-request registry :head
                            (format nil "/v2/~a/manifests/~a" repository reference)
                            :accept +oci-image-manifest-v1+)
        (declare (ignore body status))
        (gethash "docker-content-digest" headers))
    (error () nil)))
