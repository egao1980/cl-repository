(defpackage :cl-repository-client/installer
  (:use :cl)
  (:import-from :babel #:octets-to-string #:string-to-octets)
  (:import-from :flexi-streams)
  (:import-from :chipz)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:registry #:make-registry)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-manifest-raw #:pull-blob)
  (:import-from :cl-oci/digest #:format-digest #:compute-digest #:verify-digest)
  (:import-from :cl-oci/descriptor #:descriptor #:descriptor-digest #:descriptor-media-type
                #:descriptor-size #:descriptor-annotations)
  (:import-from :cl-oci/manifest #:manifest #:manifest-layers #:manifest-config
                #:manifest-artifact-type)
  (:import-from :cl-oci/media-types #:+cl-system-name-anchor-v1+)
  (:import-from :cl-oci/image-index #:image-index)
  (:import-from :cl-oci/config #:cl-system-config #:config-system-name #:config-layer-roles
                #:config-provides #:config-version #:config-cffi-libraries)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :cl-oci/annotations #:+ann-title+)
  (:import-from :yason)
  (:import-from :cl-repository-client/platform-resolver #:resolve-manifests)
  (:import-from :cl-repository-client/integrity #:record-file-manifest)
  (:export #:install-system
           #:install-result
           #:make-install-result
           #:install-result-path
           #:install-result-name
           #:install-result-version
           #:install-result-index-digest
           #:install-result-source-digest
           #:install-result-overlay-digest
           #:install-result-registry-url
           #:extract-layer
           #:extract-layer-stripping-prefix
           #:compute-strip-prefix
           #:systems-root
           #:system-install-path
           #:create-provides-symlinks
           #:parse-ocicl-layer-info))
(in-package :cl-repository-client/installer)

(defvar *systems-root*
  (merge-pathnames ".local/share/cl-repository/systems/" (user-homedir-pathname))
  "Root directory for installed systems.")

(defun systems-root () *systems-root*)

(defun safe-path-component-p (string)
  "T when STRING is safe to use as a single directory component under
   *systems-root*: non-empty, no path separators, not a dot-only name."
  (and (stringp string)
       (plusp (length string))
       (not (find #\/ string))
       (not (find #\\ string))
       (not (find #\Null string))
       (not (every (lambda (ch) (char= ch #\.)) string)))) ; rejects "." and ".."

(defun check-path-component (string what)
  "Signal an error unless STRING is a safe path component. Returns STRING.
   Guards against traversal via registry-controlled names/versions."
  (unless (safe-path-component-p string)
    (error "Unsafe ~a ~s: must be a single path component" what string))
  string)

(defun system-install-path (name version)
  "Path where a system version gets installed."
  (check-path-component name "system name")
  (check-path-component version "version")
  (merge-pathnames (format nil "~a/~a/" name version) *systems-root*))

(defstruct install-result
  "Result of installing a system, carrying path and digest info for lockfile."
  path name version index-digest source-digest overlay-digest registry-url)

(defun repository-basename (repository)
  "Last path segment of an OCI repository, e.g. \"cl-systems/alexandria\" -> \"alexandria\"."
  (let ((pos (position #\/ repository :from-end t)))
    (if pos (subseq repository (1+ pos)) repository)))

(defun pull-verified-blob (registry repository descriptor)
  "Pull the blob named by DESCRIPTOR and verify its size and digest.
   Signals an error on mismatch; returns the blob octets."
  (let* ((digest (descriptor-digest descriptor))
         (blob (pull-blob registry repository (format-digest digest)))
         (expected-size (descriptor-size descriptor)))
    (when (and expected-size (/= (length blob) expected-size))
      (error "Blob size mismatch for ~a: expected ~d bytes, got ~d"
             (format-digest digest) expected-size (length blob)))
    (verify-digest blob digest)
    blob))

(defun install-system (registry-url repository reference &key (type :cl-repo))
  "Install a CL system from an OCI registry.
   TYPE is :cl-repo (default) or :ocicl for OCICL-format packages.
   Respects *dry-run* and *quiet*.  Returns an INSTALL-RESULT."
  (let ((reg (make-registry registry-url)))
    (msg "~&Pulling ~a:~a from ~a...~%" repository reference registry-url)
    (when *dry-run*
      (msg "~&[dry-run] Would install ~a:~a~%" repository reference)
      (return-from install-system
        (make-install-result :path (system-install-path (repository-basename repository)
                                                        reference)
                             :registry-url registry-url)))
    (multiple-value-bind (body status headers)
        (pull-manifest-raw reg repository reference)
      (declare (ignore status))
      (let* ((index-digest (or (gethash "docker-content-digest" headers)
                               (format-digest (compute-digest body))))
             (json-str (etypecase body
                         (string body)
                         ((vector (unsigned-byte 8))
                          (babel:octets-to-string body :encoding :utf-8))))
             (json (yason:parse json-str))
             (media-type (or (gethash "content-type" headers) ""))
             (obj (cond
                    ((or (search "image.index" media-type)
                         (search "manifest.list" media-type)
                         (equalp (gethash "mediaType" json)
                                 "application/vnd.oci.image.index.v1+json"))
                     (from-json 'image-index json))
                    (t (from-json 'manifest json)))))
        (let ((result (if (eq type :ocicl)
                          (install-from-ocicl-manifest reg repository obj reference registry-url)
                          (etypecase obj
                            (image-index (install-from-index reg repository obj registry-url))
                            (manifest (install-from-manifest reg repository obj registry-url))))))
          (setf (install-result-index-digest result) index-digest)
          result)))))

(defun compute-strip-prefix (name version)
  "Compute the tarball prefix that the packager uses: \"<name>-<version>/\"."
  (format nil "~a-~a/" name (or version "latest")))

(defun install-from-index (registry repository index registry-url)
  "Install from an image index - resolve platform and pull appropriate manifests."
  (multiple-value-bind (universal-desc overlay-descs) (resolve-manifests index)
    (let* ((source-digest (when universal-desc
                            (format-digest (descriptor-digest universal-desc))))
           (overlay-digest (when (first overlay-descs)
                             (format-digest (descriptor-digest (first overlay-descs)))))
           (universal-manifest
             (when universal-desc
               (pull-manifest registry repository source-digest)))
           (config-json (when universal-manifest
                          (pull-verified-blob registry repository
                                              (manifest-config universal-manifest))))
           (config (when config-json
                     (from-json 'cl-system-config
                                (babel:octets-to-string config-json :encoding :utf-8))))
           (name (if config (config-system-name config) repository))
           (version (or (and config (cl-oci/config:config-version config)) "latest"))
           (strip-prefix (compute-strip-prefix name version))
           (install-dir (system-install-path name version)))
      ;; Ensure install directory
      (ensure-directories-exist (merge-pathnames "x" install-dir))
      ;; Extract universal layers (strip OCICL-compatible prefix)
      (when universal-manifest
        (dolist (layer-desc (manifest-layers universal-manifest))
          (let ((blob (pull-verified-blob registry repository layer-desc)))
            (extract-layer-stripping-prefix blob install-dir strip-prefix))))
      ;; Extract overlay layers -- skip source-role layers (already extracted
      ;; from universal manifest above; overlays include them for OCI client compat).
      ;; Non-source layers use the same OCICL prefix (e.g. "name-ver/native/..."),
      ;; so strip-prefix extraction puts files in the right subdirectory.
      (dolist (overlay-desc overlay-descs)
        (let* ((overlay-manifest
                 (pull-manifest registry repository
                                (format-digest (descriptor-digest overlay-desc))))
               (overlay-config-json
                 (pull-verified-blob registry repository
                                     (manifest-config overlay-manifest)))
               (overlay-config
                 (when overlay-config-json
                   (from-json 'cl-system-config
                              (babel:octets-to-string overlay-config-json :encoding :utf-8)))))
          (dolist (layer-desc (manifest-layers overlay-manifest))
            (let* ((layer-digest-str (format-digest (descriptor-digest layer-desc)))
                   (role (or (when overlay-config
                               (gethash layer-digest-str
                                        (config-layer-roles overlay-config)))
                             (when config
                               (gethash layer-digest-str
                                        (config-layer-roles config))))))
              (unless (string= role "source")
                (let ((blob (pull-verified-blob registry repository layer-desc)))
                  (extract-layer-stripping-prefix blob install-dir strip-prefix)))))))
      ;; Generate cl-repo-init.lisp if needed
      (when (and config (cl-oci/config:config-cffi-libraries config))
        (generate-init-file install-dir config))
      ;; Create symlinks for provided system names
      (when config
        (create-provides-symlinks name (config-provides config)))
      (record-file-manifest install-dir)
      (msg "~&Installed ~a ~a to ~a~%" name version install-dir)
      (make-install-result :path install-dir
                           :name name
                           :version version
                           :source-digest source-digest
                           :overlay-digest overlay-digest
                           :registry-url registry-url))))

(defun install-from-manifest (registry repository manifest registry-url)
  "Install from a single manifest (no index)."
  (when (and (null (manifest-layers manifest))
             (let ((at (manifest-artifact-type manifest)))
               (and at (string= at +cl-system-name-anchor-v1+))))
    (error "~a:latest is a system-name anchor (no layers). ~
            Use an explicit version tag instead." repository))
  (let* ((config-json (pull-verified-blob registry repository (manifest-config manifest)))
         (config (from-json 'cl-system-config
                            (babel:octets-to-string config-json :encoding :utf-8)))
         (name (config-system-name config))
         (version (or (cl-oci/config:config-version config) "latest"))
         (strip-prefix (compute-strip-prefix name version))
         (install-dir (system-install-path name version)))
    (ensure-directories-exist (merge-pathnames "x" install-dir))
    (dolist (layer-desc (manifest-layers manifest))
      (let ((blob (pull-verified-blob registry repository layer-desc)))
        (extract-layer-stripping-prefix blob install-dir strip-prefix)))
    (when (config-cffi-libraries config)
      (generate-init-file install-dir config))
    (create-provides-symlinks name (config-provides config))
    (record-file-manifest install-dir)
    (msg "~&Installed ~a ~a to ~a~%" name version install-dir)
    (make-install-result :path install-dir
                         :name name
                         :version version
                         :source-digest nil
                         :registry-url registry-url)))

;;; --- OCICL compatibility ---

(defun parse-ocicl-layer-info (title)
  "Parse an OCICL layer title annotation like \"alexandria-20240503-8514d8e.tar.gz\"
   into (values system-name version strip-prefix).
   Version segment starts with an 8-digit date after a dash.
   Returns NIL if TITLE is NIL."
  (when title
    (let ((base (if (search ".tar.gz" title)
                    (subseq title 0 (search ".tar.gz" title))
                    title)))
      (let ((version-pos nil))
        ;; Scan for a dash followed by 8 digits (date like 20240503)
        (loop for i from 0 below (length base)
              when (and (char= (char base i) #\-)
                        (< (+ i 8) (length base))
                        (every #'digit-char-p (subseq base (1+ i) (+ i 9))))
                do (setf version-pos i) (return))
        (if version-pos
            (values (subseq base 0 version-pos)
                    (subseq base (1+ version-pos))
                    (format nil "~a/" base))
            (values base "latest" (format nil "~a/" base)))))))

(defun install-from-ocicl-manifest (registry repository manifest reference registry-url)
  "Install from an OCICL-format manifest. Skips empty config, strips tarball prefix."
  (let* ((layers (manifest-layers manifest))
         (layer-desc (first layers))
         (ann (when layer-desc (descriptor-annotations layer-desc)))
         (title (when ann (gethash +ann-title+ ann))))
    (multiple-value-bind (name version strip-prefix)
        (parse-ocicl-layer-info title)
      (let* ((name (or name (repository-basename repository)))
             (version (or version reference))
             (install-dir (system-install-path name version)))
        (ensure-directories-exist (merge-pathnames "x" install-dir))
        (dolist (ld layers)
          (let ((blob (pull-verified-blob registry repository ld)))
            (if strip-prefix
                (extract-layer-stripping-prefix blob install-dir strip-prefix)
                (extract-layer blob install-dir))))
        (record-file-manifest install-dir)
        (msg "~&Installed ~a ~a to ~a (ocicl)~%" name version install-dir)
        (make-install-result :path install-dir
                             :name name
                             :version version
                             :registry-url registry-url)))))

(defun extract-layer-stripping-prefix (tar-gz-data target-dir prefix)
  "Extract a tar+gzip layer to TARGET-DIR, stripping PREFIX from entry names."
  (let* ((input (flexi-streams:make-in-memory-input-stream tar-gz-data))
         (decompressed (chipz:make-decompressing-stream 'chipz:gzip input)))
    (unwind-protect
         (extract-tar-stream decompressed target-dir :strip-prefix prefix)
      (close decompressed))))

(defun make-directory-link (link-path target-dir)
  "Create a directory symlink/junction LINK-PATH -> TARGET-DIR (portable)."
  (let ((link (uiop:native-namestring link-path))
        (target (uiop:native-namestring target-dir)))
    #+windows
    (uiop:run-program (list "cmd" "/c" "mklink" "/J" link target) :error-output t)
    #-windows
    (uiop:run-program (list "ln" "-s" target link) :error-output t)))

(defun create-provides-symlinks (canonical-name provides)
  "Create symlinks for provided system names that differ from the canonical name.
   E.g., systems/cffi-toolchain -> systems/cffi"
  (when provides
    (let ((canonical-dir (merge-pathnames (format nil "~a/" canonical-name) *systems-root*)))
      (dolist (provided provides)
        (unless (or (string= provided canonical-name)
                    ;; Provides names come from remote config -- never let them
                    ;; escape *systems-root* via separators or dot components.
                    (not (safe-path-component-p provided)))
          (let ((link-path (merge-pathnames (format nil "~a" provided) *systems-root*)))
            (unless (probe-file link-path)
              (handler-case
                  (progn
                    (ensure-directories-exist *systems-root*)
                    (make-directory-link link-path canonical-dir)
                    (msg "~&  Symlink ~a -> ~a~%" provided canonical-name))
                (error (e)
                  (msg "~&  Warning: could not create symlink ~a: ~a~%" provided e))))))))))

(defun role-subdirectory (role)
  "Map a layer role to its extraction subdirectory."
  (cond
    ((or (null role) (string= role "source")) nil)
    ((string= role "native-library") "native")
    ((string= role "static-library") "native")
    ((string= role "cffi-grovel-output") "grovel-cache")
    ((string= role "cffi-wrapper") "native")
    ((string= role "headers") "headers")
    ((string= role "documentation") "docs")
    ((string= role "build-script") nil)
    (t nil)))

(defun extract-layer (tar-gz-data target-dir)
  "Extract a tar+gzip layer to TARGET-DIR."
  (let* ((input (flexi-streams:make-in-memory-input-stream tar-gz-data))
         (decompressed (chipz:make-decompressing-stream 'chipz:gzip input)))
    (unwind-protect
         (extract-tar-stream decompressed target-dir)
      (close decompressed))))

(defun safe-tar-entry-name-p (name)
  "T when tar entry NAME is safe to extract under a target directory:
   relative, no .. components, and free of characters that could redirect
   the resulting pathname (backslash, NUL, wildcards, leading ~)."
  (and (plusp (length name))
       (char/= (char name 0) #\/)
       (char/= (char name 0) #\~)
       (not (find-if (lambda (ch) (member ch '(#\\ #\Null #\* #\? #\[))) name))
       (loop for start = 0 then (1+ end)
             for end = (or (position #\/ name :start start) (length name))
             never (string= name ".." :start1 start :end1 end)
             until (>= end (length name)))))

(defun extract-tar-stream (stream target-dir &key strip-prefix)
  "Extract tar entries from STREAM to TARGET-DIR.
   When STRIP-PREFIX is given, remove that prefix from each entry name.
   Signals an error on entries that would escape TARGET-DIR (tar slip)."
  (loop
    (let ((header (make-array 512 :element-type '(unsigned-byte 8))))
      (let ((bytes-read (read-sequence header stream)))
        (when (or (< bytes-read 512) (every #'zerop header))
          (return)))
      (let* ((raw-name (parse-tar-name header))
             (name (if (and strip-prefix
                            (>= (length raw-name) (length strip-prefix))
                            (string= raw-name strip-prefix :end1 (length strip-prefix)))
                       (subseq raw-name (length strip-prefix))
                       raw-name))
             (size (parse-tar-size header))
             (type (aref header 156)))
        (when (and (plusp (length name))
                   (not (string= name "./"))
                   (not (safe-tar-entry-name-p name)))
          (error "Refusing to extract unsafe tar entry ~s (path traversal?)" raw-name))
        (if (or (zerop (length name)) (string= name "./"))
            (skip-tar-data stream size)
            (cond
              ((or (= type (char-code #\5))
                   (and (or (= type (char-code #\0)) (= type 0))
                        (plusp (length name))
                        (char= (char name (1- (length name))) #\/)))
               (ensure-directories-exist (merge-pathnames (format nil "~a/" name) target-dir))
               (skip-tar-data stream size))
              ((or (= type (char-code #\0)) (= type 0))
               (let* ((content (make-array size :element-type '(unsigned-byte 8)))
                      (path (merge-pathnames name target-dir)))
                 (read-sequence content stream)
                 (let ((remainder (mod size 512)))
                   (when (plusp remainder)
                     (let ((pad (make-array (- 512 remainder) :element-type '(unsigned-byte 8))))
                       (read-sequence pad stream))))
                 (ensure-directories-exist path)
                 (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                           :if-exists :supersede)
                   (write-sequence content out))))
              (t
               (skip-tar-data stream size))))))))

(defun skip-tar-data (stream size)
  "Skip SIZE bytes of tar data (padded to 512-byte blocks)."
  (let ((buf (make-array 512 :element-type '(unsigned-byte 8))))
    (dotimes (i (ceiling size 512))
      (read-sequence buf stream))))

(defun parse-tar-name (header)
  (let ((end (or (position 0 header :end 100) 100)))
    (babel:octets-to-string (subseq header 0 end) :encoding :utf-8)))

(defun parse-tar-size (header)
  (let* ((str (babel:octets-to-string (subseq header 124 136) :encoding :ascii))
         (trimmed (string-trim '(#\Space #\Null) str)))
    (if (zerop (length trimmed)) 0 (parse-integer trimmed :radix 8))))

(defun shared-library-pathname-p (path)
  "True if PATH looks like a loadable shared library (.so/.so.*/.dylib/.dll)."
  (let ((s (file-namestring path)))
    (and (plusp (length s))
         (or (and (>= (length s) 3) (string-equal ".so" s :start2 (- (length s) 3)))
             (search ".so." s :test #'char-equal)
             (and (>= (length s) 6) (string-equal ".dylib" s :start2 (- (length s) 6)))
             (and (>= (length s) 4) (string-equal ".dll" s :start2 (- (length s) 4)))))))

(defun list-native-shared-libraries (install-dir)
  "Pathnames of shared libraries under INSTALL-DIR/native/.

   Uses INSTALL-DIR as given (no truename) so generated init files keep the
   install path the client will load from (macOS /tmp vs /private/tmp, bind mounts)."
  (let ((native (merge-pathnames "native/" (uiop:ensure-directory-pathname install-dir))))
    (when (uiop:directory-exists-p native)
      (remove-if-not #'shared-library-pathname-p
                     (uiop:directory-files native)))))

(defun sort-native-libs-for-preload (pathnames)
  "Load libcrypto before libssl; otherwise lexicographic by file name."
  (stable-sort
   (copy-list pathnames)
   (lambda (a b)
     (flet ((rank (p)
              (let ((s (string-downcase (file-namestring p))))
                (cond ((search "crypto" s) 0)
                      ((search "ssl" s) 1)
                      (t 2)))))
       (let ((ra (rank a)) (rb (rank b)))
         (if (= ra rb)
             (string< (file-namestring a) (file-namestring b))
             (< ra rb)))))))

(defun generate-init-file (install-dir config)
  "Generate cl-repo-init.lisp wiring this system's bundled native libs into CFFI.

   1. Pushes native/ (and per-library :search-path) onto
      cffi:*foreign-library-directories*.
   2. Eagerly LOAD-FOREIGN-LIBRARY each shared object under native/ by
      absolute path so distro libs with the same soname (e.g. libssl.so.3)
      cannot win via bare dlopen — init runs before asdf:load-system
      (native-deps.md, Post-Install).

   CONFIG holds the canonical cffi-libraries alist (NAME . PLIST)."
  (let ((init-path (merge-pathnames "cl-repo-init.lisp" install-dir))
        (libs (config-cffi-libraries config))
        (dir (namestring (uiop:ensure-directory-pathname install-dir)))
        (native-libs (sort-native-libs-for-preload
                      (or (list-native-shared-libraries install-dir) '()))))
    (with-open-file (out init-path :direction :output :if-exists :supersede)
      (format out ";;; Auto-generated by cl-repository-client. Do not edit.~%")
      (format out "(in-package :cl-user)~%~%")
      (format out "(unless (find-package :cffi)~%")
      (format out "  (ignore-errors (asdf:load-system \"cffi\")))~%~%")
      (format out "(when (find-package :cffi)~%")
      (format out "  (flet ((add-dir (rel)~%")
      (format out "           (pushnew (merge-pathnames rel ~s)~%" dir)
      (format out "                    (symbol-value (find-symbol \"*FOREIGN-LIBRARY-DIRECTORIES*\" :cffi))~%")
      (format out "                    :test #'equal))~%")
      (format out "         (preload (path)~%")
      (format out "           (handler-case~%")
      (format out "               (funcall (find-symbol \"LOAD-FOREIGN-LIBRARY\" :cffi) path)~%")
      (format out "             (error (c)~%")
      ;; ~~ escapes tilde so FORMAT does not consume args for the generated warn form.
      (format out "               (warn \"cl-repo: preload ~~A failed: ~~A\" path c)))))~%")
      (format out "    (add-dir \"native/\")  ; native-library/static-library overlays~%")
      (dolist (lib libs)
        (destructuring-bind (name . plist) lib
          (let ((search-path (getf plist :search-path))
                (foreign-lib (getf plist :define-foreign-library))
                (canary (getf plist :canary)))
            (format out "    ;; ~a~@[ - define-foreign-library ~a~]~@[, canary ~a~]~%"
                    name foreign-lib canary)
            (when (and search-path (not (string= search-path "native/")))
              (format out "    (add-dir ~s)~%" search-path)))))
      (when native-libs
        (format out "    ;; Absolute preload (before dependent systems dlopen bare sonames)~%")
        (dolist (lib-path native-libs)
          (format out "    (preload ~s)~%" (namestring lib-path))))
      (format out "    (values)))~%"))))
