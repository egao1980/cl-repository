(defpackage :cl-repository-client/quickload
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:make-registry)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-blob)
  (:import-from :cl-oci-client/content-discovery #:list-tags #:list-referrers)
  (:import-from :cl-oci-client/conditions #:registry-error)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests)
  (:import-from :cl-oci/manifest #:manifest #:manifest-artifact-type #:manifest-config
                #:manifest-annotations)
  (:import-from :cl-oci/descriptor #:descriptor-digest #:descriptor-annotations)
  (:import-from :cl-oci/digest #:format-digest)
  (:import-from :cl-oci/media-types #:+cl-system-name-anchor-v1+ #:+cl-system-artifact-type+)
  (:import-from :cl-oci/annotations #:+ann-version+ #:+cl-alias-for+)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :cl-oci/config #:cl-system-config)
  (:import-from :cl-repository-client/installer #:install-system #:install-result
                #:install-result-path #:install-result-name #:install-result-version
                #:install-result-index-digest #:install-result-source-digest
                #:install-result-overlay-digest #:install-result-registry-url
                #:systems-root #:system-install-path)
  (:import-from :cl-repository-client/digest-cache
                #:digest-already-installed-p #:record-installed-digest #:load-digest-cache)
  (:import-from :cl-repository-client/constraint-builder
                #:build-install-plan #:dependency-resolution-error)
  (:import-from :cl-repository-client/version-utils #:select-preferred-version)
  (:import-from :cl-repository-client/asdf-integration #:configure-asdf-source-registry
                #:load-system-init-files)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-entry #:add-lockfile-entry)
  (:import-from :babel #:octets-to-string)
  (:export #:*registries*
           #:add-registry
           #:load-system))
(in-package :cl-repository-client/quickload)

(defvar *registries* nil
  "Ordered list of OCI registries to search.
   Each entry is (URL &key namespace type).
   TYPE is :cl-repo (default) or :ocicl.
   Example:
     ((\"http://localhost:5050\" :namespace \"cl-systems\")
      (\"https://ghcr.io\" :namespace \"ocicl\" :type :ocicl))")

(defun add-registry (url &key (namespace "cl-systems") (priority :append) (type :cl-repo))
  "Add a registry to *registries*.
   PRIORITY is :prepend (search first) or :append (search last).
   TYPE is :cl-repo (default) or :ocicl for OCICL-format registries.
   Avoids duplicates by URL+namespace."
  (let ((entry (list url :namespace namespace :type type)))
    (unless (find-if (lambda (e)
                       (and (string= (first e) url)
                            (string= (registry-namespace e) namespace)))
                     *registries*)
      (ecase priority
        (:prepend (push entry *registries*))
        (:append (setf *registries* (append *registries* (list entry)))))))
  *registries*)

(defun registry-url (entry) (first entry))
(defun registry-namespace (entry) (getf (rest entry) :namespace "cl-systems"))
(defun registry-type (entry) (getf (rest entry) :type :cl-repo))

;;; System presence checks

(defun system-already-installed-p (name)
  "Check if any version of NAME is installed locally, following symlinks."
  (let ((dir (merge-pathnames (format nil "~a/" name) (systems-root))))
    (or (and (probe-file dir)
             (uiop:subdirectories dir))
        (handler-case
            (let ((real (truename dir)))
              (and real (uiop:subdirectories real)))
          (error () nil)))))

(defun installed-system-version (name)
  "Return installed version string for NAME, or NIL."
  (let ((dir (merge-pathnames (format nil "~a/" name) (systems-root))))
    (handler-case
        (let ((real-dir (truename dir)))
          (when real-dir
            (let ((subdirs (uiop:subdirectories real-dir)))
              (when subdirs
                (car (last (pathname-directory (first (last subdirs)))))))))
      (error () nil))))

;;; Lockfile integration

(defun record-lockfile-entry (result)
  "Create a lockfile entry from an INSTALL-RESULT and append it to cl-repo.lock."
  (handler-case
      (when (and (install-result-name result)
                 (install-result-version result))
        (add-lockfile-entry
         (make-instance 'lockfile-entry
                        :system (install-result-name result)
                        :version (install-result-version result)
                        :index-digest (or (install-result-index-digest result) "")
                        :source-digest (install-result-source-digest result)
                        :overlay-digest (install-result-overlay-digest result)
                        :registry (or (install-result-registry-url result) ""))))
    (error (e)
      (msg "~&; cl-repo: warning: could not update lockfile: ~a~%" e))))

;;; Direct system install (for single system, bypasses SAT)

(defun find-system-in-registry (reg-url namespace system-name &key version (type :cl-repo))
  "Find SYSTEM-NAME in a registry. Returns (values repo tag) or NIL.
   If VERSION given, uses it directly. Otherwise discovers via tags or anchor.
   For :ocicl registries, the repo is just the system name (no namespace nesting)."
  (let* ((repo (if (eq type :ocicl)
                   (format nil "~a/~a" namespace system-name)
                   (format nil "~a/~a" namespace system-name)))
         (reg (make-registry reg-url)))
    (handler-case
        (if version
            (values repo version)
            (let ((tags (list-tags reg repo)))
              (if tags
                  (let ((version-tags (remove "latest" tags :test #'string=)))
                    (if version-tags
                        (values repo (select-preferred-version version-tags))
                        (values repo (first tags))))
                  (unless (eq type :ocicl)
                    (find-via-anchor reg repo system-name)))))
      (error () nil))))

(defun find-via-anchor (registry repo system-name)
  "Try to find system via system-name anchor at :latest."
  (handler-case
      (let ((obj (pull-manifest registry repo "latest")))
        (when (and (typep obj 'manifest)
                   (string= (manifest-artifact-type obj) +cl-system-name-anchor-v1+))
          ;; It's a system-name anchor -- read alias-for
          (let* ((ann (manifest-annotations obj))
                 (alias-for (gethash +cl-alias-for+ ann))
                 (version (gethash +ann-version+ ann)))
            (when (and alias-for version)
              ;; The actual package is at the alias-for repo
              (let ((alias-repo (format nil "~a/~a"
                                        (subseq repo 0 (position #\/ repo :from-end t))
                                        alias-for)))
                (values alias-repo version))))))
    (error () nil)))

(defun ensure-system-installed (name &key version)
  "Install NAME from configured registries. Returns INSTALL-RESULT or NIL."
  (dolist (entry *registries* nil)
    (let ((url (registry-url entry))
          (ns (registry-namespace entry))
          (type (registry-type entry)))
      (handler-case
          (multiple-value-bind (repo tag)
              (find-system-in-registry url ns name :version version :type type)
            (when (and repo tag)
              (msg "~&; cl-repo: found ~a:~a in ~a (~a)~%" name tag url type)
              (return-from ensure-system-installed
                (install-system url repo tag :type type))))
        (error (e)
          (msg "~&; cl-repo: ~a not in ~a (~a)~%" name url e))))))

;;; Main entry point

(defun load-system (systems &key silent version force)
  "Install (if needed) and load Common Lisp systems from OCI registries.
   Uses SAT solver for transitive dependency resolution with version constraints.
   SYSTEMS: system name (string/symbol) or list of them.
   SILENT: suppress output. VERSION: pin specific tag. FORCE: re-resolve even if installed.

   Usage:
     (cl-repo:load-system \"alexandria\")
     (cl-repo:load-system '(\"alexandria\" \"cl-ppcre\") :silent t)
     (cl-repo:load-system \"my-app\" :force t)  ; re-resolve and upgrade deps"
  (let* ((*quiet* (or *quiet* silent))
         (system-list (if (listp systems) systems (list systems)))
         (installed-any nil))
    ;; Load digest cache on first use
    (load-digest-cache)
    ;; Phase 1: Build install plan via SAT solver for systems not yet available
    (let ((plan (compute-install-plan system-list :version version :force force)))
      ;; Phase 2: Install everything in the plan
      (dolist (entry plan)
        (let ((name (car entry))
              (ver (cdr entry)))
          (unless (and (not force)
                       (system-already-installed-p name)
                       (let ((iv (installed-system-version name)))
                         (and iv (string= iv ver))))
            (let ((result (ensure-system-installed name :version ver)))
              (when result
                (setf installed-any t)
                (configure-asdf-source-registry)
                (record-lockfile-entry result))))))
      ;; Phase 3: Load via ASDF
      (configure-asdf-source-registry)
      (load-system-init-files)
      (dolist (sys system-list)
        (let ((name (string-downcase (string sys))))
          (msg "~&; cl-repo: loading ~a~%" name)
          (handler-case (asdf:load-system name)
            (error (e)
              (msg "~&; cl-repo: failed to load ~a: ~a~%" name e))))))
    (if (= (length system-list) 1)
        (first system-list)
        system-list)))

(defun compute-install-plan (system-names &key version force)
  "Use SAT solver to compute full transitive install plan.
   Pins already-installed systems unless FORCE is true."
  (let ((plan nil))
    (dolist (name-raw system-names)
      (let ((name (string-downcase (string name-raw))))
        (if (and (not force) (asdf:find-system name nil))
            (msg "~&; cl-repo: ~a already available via ASDF~%" name)
            (handler-case
                (let ((resolved (build-install-plan name (or version :latest) *registries*
                                                    :force force)))
                  (dolist (entry resolved)
                    (unless (find (car entry) plan :key #'car :test #'string=)
                      (push entry plan))))
              (dependency-resolution-error (e)
                (msg "~&; cl-repo: ~a~%" e))
              (error (e)
                ;; Fall back to direct install without SAT for simple cases
                (msg "~&; cl-repo: SAT resolution unavailable for ~a (~a), trying direct~%" name e)
                (unless (system-already-installed-p name)
                  (push (cons name (or version "latest")) plan)))))))
    (nreverse plan)))
