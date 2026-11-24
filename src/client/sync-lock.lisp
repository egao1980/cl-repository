(defpackage :cl-repository-client/sync-lock
  (:use :cl)
  (:import-from :cl-oci/runtime #:msg)
  (:import-from :cl-oci/system-names #:oci-package-name)
  (:import-from :cl-repository-client/registry-auth #:pull-registry)
  (:import-from :cl-oci-client/pull #:head-manifest)
  (:import-from :cl-oci-client/conditions #:registry-error #:registry-transport-error
                #:not-found-error #:credentials-rejected)
  (:import-from :cl-repository-client/installer
                #:systems-root #:system-install-path #:install-system #:installed-package
                #:install-result-path #:install-result-name #:install-result-version
                #:install-result-index-digest #:install-result-source-digest
                #:install-result-overlay-digest #:install-result-overlay-digests
                #:install-result-registry-url)
  (:import-from :cl-repository-client/lockfile
                #:lockfile-entry #:lockfile-path
                #:lockfile-entry-system #:lockfile-entry-version
                #:lockfile-entry-index-digest #:lockfile-entry-registry)
  (:import-from :cl-repository-client/protected-systems #:implementation-system-p)
  (:import-from :cl-repository-client/config-store #:stored-entry)
  (:import-from :cl-repository-client/digest-cache
                #:*installed-digests* #:load-digest-cache #:record-installed-digest)
  (:import-from :cl-repository-client/source-policy #:system-denied-p #:registry-allowed-p)
  (:import-from :cl-repository-client/quickload #:*registries*)
  (:import-from :cl-repository-client/commands
                #:verify-lockfile-entry-digest #:*default-namespace*)
  (:export #:lockfile-not-current
           #:lockfile-not-current-path
           #:lockfile-not-current-reason
           #:lockfile-stale-reason
           #:closure-packages
           #:closure-lock-entries
           #:lockfile-closure-gap
           #:lockfile-policy-gap
           #:lockfile-reproduction-gap
           #:install-lockfile-entries
           #:lockfile-entry-unavailable
           #:lockfile-entry-unavailable-system))
(in-package :cl-repository-client/sync-lock)

;;; cl-repo.lock as the record of a project's dependency closure: the
;;; package and version each system the closure needs is loaded from, as
;;; the project registry (and so the test image) resolves it. A sync that
;;; resolves writes it; a sync that finds it current installs from it.

(define-condition lockfile-not-current (error)
  ((path :initarg :path :reader lockfile-not-current-path)
   (reason :initarg :reason :reader lockfile-not-current-reason))
  (:documentation
   "A sync or test with --locked found cl-repo.lock missing, older than a
    project .asd or qlfile, or not locking the dependency closure, and was not
    allowed to resolve.")
  (:report (lambda (c s)
             (format s "cl-repo: ~a is not current: ~a. ~
                        Run cl-repo sync without --locked to resolve and rewrite it."
                     (uiop:native-namestring (lockfile-not-current-path c))
                     (lockfile-not-current-reason c)))))

(define-condition lockfile-entry-unavailable (error)
  ((system :initarg :system :reader lockfile-entry-unavailable-system)
   (version :initarg :version :reader lockfile-entry-unavailable-version)
   (registry :initarg :registry :reader lockfile-entry-unavailable-registry :initform nil)
   (cause :initarg :cause :reader lockfile-entry-unavailable-cause :initform nil))
  (:documentation
   "A sync from cl-repo.lock needs an entry that is not installed, and its
    registry gave no answer (CAUSE, a REGISTRY-TRANSPORT-ERROR: unreachable,
    or a transfer that kept failing). Not an absent package or tag: nothing
    was learnt about it.")
  (:report (lambda (c s)
             (format s "cl-repo: ~a ~a (cl-repo.lock) is not installed, and ~
                        ~:[its registry~;~:*~a~] could not be asked for it: ~a"
                     (lockfile-entry-unavailable-system c)
                     (lockfile-entry-unavailable-version c)
                     (lockfile-entry-unavailable-registry c)
                     (lockfile-entry-unavailable-cause c)))))

(defun project-input-files (directory)
  "The files the dependencies of the project in DIRECTORY are declared in:
   its top-level .asd files, qlfile and qlfile.lock."
  (let ((dir (uiop:ensure-directory-pathname directory)))
    (append (directory (merge-pathnames "*.asd" dir))
            (remove-if-not #'probe-file
                           (list (merge-pathnames "qlfile" dir)
                                 (merge-pathnames "qlfile.lock" dir))))))

(defun lockfile-stale-reason (directory)
  "NIL when DIRECTORY has a cl-repo.lock that no project .asd, qlfile or
   qlfile.lock is newer than (file write dates). Otherwise why not, a phrase."
  (let* ((lock (lockfile-path (uiop:ensure-directory-pathname directory)))
         (date (and (probe-file lock) (file-write-date lock))))
    (if (null date)
        "there is no cl-repo.lock"
        (let ((newer (find-if (lambda (file)
                                (let ((d (file-write-date file)))
                                  (and d (> d date))))
                              (project-input-files directory))))
          (and newer (format nil "~a is newer" (file-namestring newer)))))))

;;; The closure's packages

(defun closure-packages (names)
  "Alist (package . version), sorted by package, of the installed packages a
   fresh image under the current source registry loads the systems NAMES (a
   dependency closure) from. A system the implementation provides, or one
   found outside the install tree (the project, the client's own trees,
   CL_SOURCE_REGISTRY trees), has no package."
  (let ((packages '()))
    (dolist (name names)
      (unless (implementation-system-p name)
        (multiple-value-bind (package version)
            (installed-package (asdf/source-registry:sysdef-source-registry-search name))
          (when (and package (not (assoc package packages :test #'string=)))
            (push (cons package version) packages)))))
    (sort packages #'string< :key #'car)))

;;; Digests for new entries, from what is already known

(defun registry-namespace (entry)
  (getf (rest entry) :namespace *default-namespace*))

(defun package-registries (package)
  "The *REGISTRIES* entries source policy lets PACKAGE come from."
  (remove-if-not (lambda (entry) (registry-allowed-p package (first entry))) *registries*))

(defun package-repository (entry package)
  (format nil "~a/~a" (registry-namespace entry) (oci-package-name package)))

(defun cached-digest (package version)
  "The digest the digest cache recorded for the install of PACKAGE VERSION."
  (let ((path (namestring (system-install-path package version))))
    (loop for digest being the hash-keys of *installed-digests* using (hash-value where)
          when (equal where path)
            return digest)))

(defun local-digest (package version)
  "(values digest registry-url) of PACKAGE VERSION from what is on disk: the
   digest cache (what was installed), else the config store (the tag when
   resolution read it). NIL when neither has it."
  (let ((registries (package-registries package)))
    (let ((digest (cached-digest package version)))
      (when digest
        (return-from local-digest (values digest (first (first registries))))))
    (dolist (entry registries nil)
      (let ((stored (stored-entry (first entry) (package-repository entry package) version)))
        (when stored
          (return (values (getf stored :digest) (first entry))))))))

(defun remote-digest (package version)
  "(values digest registry-url) of PACKAGE VERSION from a HEAD of the tag in
   the first registry that answers with one, or NIL. Refused credentials
   (CREDENTIALS-REJECTED) signal: they are not an absent tag."
  (dolist (entry (package-registries package) nil)
    (handler-case
        (multiple-value-bind (status headers)
            (head-manifest (pull-registry (first entry)) (package-repository entry package)
                           version)
          (let ((digest (and status (= status 200) headers
                             (gethash "docker-content-digest" headers))))
            (when digest
              (return (values digest (first entry))))))
      (credentials-rejected (e) (error e))
      ((or registry-error registry-transport-error) () nil))))

(defun same-version-p (version entry-version)
  (equal version (princ-to-string entry-version)))

(defun lock-entry (package version &key installs previous)
  "The lock entry of PACKAGE VERSION, with the first digest known of: this
   sync's install of it (INSTALLS, INSTALL-RESULTs), the old lock's entry
   (PREVIOUS), the digest cache or config store (LOCAL-DIGEST). Only a
   package the old lock did not have at VERSION is asked of a registry
   (REMOTE-DIGEST); with no answer its digest is \"\"."
  (let ((installed (find-if (lambda (r)
                              (and (equal (install-result-name r) package)
                                   (same-version-p version (install-result-version r))
                                   (install-result-index-digest r)))
                            installs))
        (old (find-if (lambda (e)
                        (and (equal (lockfile-entry-system e) package)
                             (same-version-p version (lockfile-entry-version e))))
                      previous)))
    ;; URL optional: REMOTE-DIGEST returns a single NIL when no registry answers
    (flet ((entry (digest &optional url)
             (make-instance 'lockfile-entry
                            :system package :version version
                            :index-digest (or digest "") :registry (or url ""))))
      (cond
       (installed
        (make-instance 'lockfile-entry
                       :system package :version version
                       :index-digest (install-result-index-digest installed)
                       :source-digest (install-result-source-digest installed)
                       :overlay-digest (install-result-overlay-digest installed)
                       :overlay-digests (install-result-overlay-digests installed)
                       :registry (or (install-result-registry-url installed) "")))
       ((and old (plusp (length (lockfile-entry-index-digest old))))
        old)
       (t
        (multiple-value-bind (digest url) (local-digest package version)
          (cond (digest (entry digest url))
                (old old)
                (t (multiple-value-call #'entry (remote-digest package version))))))))))

(defun closure-lock-entries (names &key installs previous)
  "Lock entries, sorted, for the packages the dependency closure NAMES is
   loaded from (CLOSURE-PACKAGES), at the versions the registry resolves.
   Digests come from INSTALLS and PREVIOUS before anything is asked of a
   registry (LOCK-ENTRY)."
  (load-digest-cache)
  (loop for (package . version) in (closure-packages names)
        collect (lock-entry package version :installs installs :previous previous)))

;;; Is a lock current?

(defun lockfile-closure-gap (entries names)
  "NIL when ENTRIES lock every package the closure NAMES is loaded from, at
   the version the registry resolves. Otherwise what they do not, a phrase."
  (let ((gaps (loop for (package . version) in (closure-packages names)
                    for entry = (find package entries :key #'lockfile-entry-system
                                                      :test #'string=)
                    unless (and entry (same-version-p version (lockfile-entry-version entry)))
                      collect (if entry
                                  (format nil "~a ~a (locked: ~a)"
                                          package version (lockfile-entry-version entry))
                                  (format nil "~a ~a" package version)))))
    (when gaps
      (format nil "it does not lock ~{~a~^, ~}" gaps))))

(defun lockfile-policy-gap (entries)
  "NIL when source policy lets every entry of ENTRIES come from its registry.
   Otherwise which it does not, a phrase."
  (let ((denied (loop for entry in entries
                      for name = (lockfile-entry-system entry)
                      for url = (lockfile-entry-registry entry)
                      when (or (system-denied-p name)
                               (and (plusp (length url)) (not (registry-allowed-p name url))))
                        collect name)))
    (when denied
      (format nil "source policy does not allow ~{~a~^, ~}" denied))))

(defun unreproducible-entry-p (entry)
  "True when ENTRY records neither an index digest nor a registry: nothing
   says where its version came from. A local-only install writes one
   (`cl-repo install cl-utilities` put its only tag, a commit, in
   cl-utilities/latest/, and no registry has a tag latest: #163)."
  (and (zerop (length (or (lockfile-entry-index-digest entry) "")))
       (zerop (length (or (lockfile-entry-registry entry) "")))))

(defun lockfile-reproduction-gap (entries)
  "NIL when every entry of ENTRIES that is not installed can be installed
   from what it records. Otherwise which cannot, a phrase. An entry like that
   which is installed is no gap: this machine needs nothing from a registry."
  (let ((lost (loop for entry in entries
                    when (and (unreproducible-entry-p entry)
                              (not (lock-entry-installed-p entry)))
                      collect (format nil "~a ~a" (lockfile-entry-system entry)
                                      (lockfile-entry-version entry)))))
    (when lost
      (format nil "it records no registry or digest for ~{~a~^, ~}, not installed here" lost))))

;;; Installing a lock

(defun entry-source (entry)
  "(values registry-url repository type) to install ENTRY from: its registry
   (with that registry's namespace when it is configured), else the first one
   source policy allows."
  (let* ((name (lockfile-entry-system entry))
         (url (or (lockfile-entry-registry entry) ""))
         (chosen (cond ((find url *registries* :key #'first :test #'string=))
                       ((plusp (length url)) (list url :namespace *default-namespace*))
                       (t (first (package-registries name))))))
    (unless chosen
      (error "cl-repo: no registry to install ~a from" name))
    (values (first chosen) (package-repository chosen name)
            (getf (rest chosen) :type :cl-repo))))

(defun lock-entry-installed-p (entry)
  (uiop:directory-exists-p
   (system-install-path (lockfile-entry-system entry)
                        (princ-to-string (lockfile-entry-version entry)))))

(defun entry-reference (entry registry repository version)
  "The reference to pull ENTRY by: VERSION, its tag, once the registry has
   shown that the tag still names the digest ENTRY records
   (LOCKFILE-DIGEST-MISMATCH otherwise). When the registry has no such tag and
   ENTRY records a digest, the digest itself: a package whose .asd has no
   :version is installed as \"latest\", which need not be a tag (#163)."
  (let ((digest (or (lockfile-entry-index-digest entry) "")))
    (block found
      (handler-bind ((not-found-error
                      (lambda (e)
                        (declare (ignore e))
                        (when (plusp (length digest))
                          (msg "~&; cl-repo: no tag ~a for ~a; pulling ~a~%"
                               version (lockfile-entry-system entry) digest)
                          (return-from found digest)))))
        (verify-lockfile-entry-digest entry registry repository version)
        version))))

(defun install-lockfile-entries (entries)
  "Install each entry of ENTRIES whose version is not in the install tree, by
   its tag, once the registry has shown that the tag still names the digest
   the entry records (LOCKFILE-DIGEST-MISMATCH otherwise), or by the digest
   when there is no such tag (ENTRY-REFERENCE). Nothing is resolved and no
   tag is listed. A registry that gives no answer (REGISTRY-TRANSPORT-ERROR,
   such as REGISTRY-UNREACHABLE) signals LOCKFILE-ENTRY-UNAVAILABLE naming
   the entry. → the INSTALL-RESULTs."
  (loop for entry in entries
        unless (lock-entry-installed-p entry)
          collect (multiple-value-bind (url repo type) (entry-source entry)
                    (let ((version (princ-to-string (lockfile-entry-version entry)))
                          (registry (pull-registry url)))
                      (msg "~&; cl-repo: installing ~a ~a from cl-repo.lock~%"
                           (lockfile-entry-system entry) version)
                      (handler-case
                          (let ((result (install-system url repo
                                                        (entry-reference entry registry repo version)
                                                        :type type)))
                            (when (install-result-index-digest result)
                              (record-installed-digest (install-result-index-digest result)
                                                       (install-result-path result)))
                            result)
                        (registry-transport-error (e)
                          (error 'lockfile-entry-unavailable
                                 :system (lockfile-entry-system entry) :version version
                                 :registry url :cause e)))))))
