(defpackage :cl-repository-client/installer
  (:use :cl)
  (:import-from :babel #:octets-to-string #:string-to-octets)
  (:import-from :flexi-streams)
  (:import-from :chipz)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:registry #:make-registry)
  (:import-from :cl-oci-client/pull #:pull-manifest #:pull-blob)
  (:import-from :cl-oci/digest #:format-digest)
  (:import-from :cl-oci/descriptor #:descriptor #:descriptor-digest #:descriptor-media-type
                #:descriptor-annotations)
  (:import-from :cl-oci/manifest #:manifest #:manifest-layers #:manifest-config)
  (:import-from :cl-oci/image-index #:image-index)
  (:import-from :cl-oci/config #:cl-system-config #:config-system-name #:config-layer-roles
                #:config-provides #:config-version)
  (:import-from :cl-oci/serialization #:from-json)
  (:import-from :cl-oci/annotations #:+ann-title+)
  (:import-from :cl-repository-client/platform-resolver #:resolve-manifests)
  (:export #:install-system
           #:extract-layer
           #:extract-layer-stripping-prefix
           #:systems-root
           #:system-install-path
           #:create-provides-symlinks
           #:parse-ocicl-layer-info))
(in-package :cl-repository-client/installer)

(defvar *systems-root*
  (merge-pathnames ".local/share/cl-repository/systems/" (user-homedir-pathname))
  "Root directory for installed systems.")

(defun systems-root () *systems-root*)

(defun system-install-path (name version)
  "Path where a system version gets installed."
  (merge-pathnames (format nil "~a/~a/" name version) *systems-root*))

(defun install-system (registry-url repository reference &key (type :cl-repo))
  "Install a CL system from an OCI registry.
   TYPE is :cl-repo (default) or :ocicl for OCICL-format packages.
   Respects *dry-run* and *quiet*.  Returns the installation path."
  (let ((reg (make-registry registry-url)))
    (msg "~&Pulling ~a:~a from ~a...~%" repository reference registry-url)
    (when *dry-run*
      (msg "~&[dry-run] Would install ~a:~a~%" repository reference)
      (return-from install-system (system-install-path repository reference)))
    (let ((obj (pull-manifest reg repository reference)))
      (if (eq type :ocicl)
          (install-from-ocicl-manifest reg repository obj reference)
          (etypecase obj
            (image-index (install-from-index reg repository obj))
            (manifest (install-from-manifest reg repository obj)))))))

(defun install-from-index (registry repository index)
  "Install from an image index - resolve platform and pull appropriate manifests."
  (multiple-value-bind (universal-desc overlay-descs) (resolve-manifests index)
    (let* ((universal-manifest
             (when universal-desc
               (pull-manifest registry repository
                              (format-digest (descriptor-digest universal-desc)))))
           (config-json (when universal-manifest
                          (pull-blob registry repository
                                     (format-digest
                                      (descriptor-digest
                                       (manifest-config universal-manifest))))))
           (config (when config-json
                     (from-json 'cl-system-config
                                (babel:octets-to-string config-json :encoding :utf-8))))
           (name (if config (config-system-name config) repository))
           (version (or (and config (cl-oci/config:config-version config)) "latest"))
           (install-dir (system-install-path name version)))
      ;; Ensure install directory
      (ensure-directories-exist (merge-pathnames "x" install-dir))
      ;; Extract universal layers
      (when universal-manifest
        (dolist (layer-desc (manifest-layers universal-manifest))
          (let ((blob (pull-blob registry repository
                                 (format-digest (descriptor-digest layer-desc)))))
            (extract-layer blob install-dir))))
      ;; Extract overlay layers
      (dolist (overlay-desc overlay-descs)
        (let ((overlay-manifest
                (pull-manifest registry repository
                               (format-digest (descriptor-digest overlay-desc)))))
          (dolist (layer-desc (manifest-layers overlay-manifest))
            (let* ((blob (pull-blob registry repository
                                    (format-digest (descriptor-digest layer-desc))))
                   (role (when config
                           (gethash (format-digest (descriptor-digest layer-desc))
                                    (config-layer-roles config))))
                   (subdir (role-subdirectory role)))
              (extract-layer blob (if subdir
                                      (merge-pathnames (format nil "~a/" subdir) install-dir)
                                      install-dir))))))
      ;; Generate cl-repo-init.lisp if needed
      (when (and config (cl-oci/config:config-cffi-libraries config))
        (generate-init-file install-dir config))
      ;; Create symlinks for provided system names
      (when config
        (create-provides-symlinks name (config-provides config)))
      (msg "~&Installed ~a ~a to ~a~%" name version install-dir)
      install-dir)))

(defun install-from-manifest (registry repository manifest)
  "Install from a single manifest (no index)."
  (let* ((config-json (pull-blob registry repository
                                 (format-digest
                                  (descriptor-digest (manifest-config manifest)))))
         (config (from-json 'cl-system-config
                            (babel:octets-to-string config-json :encoding :utf-8)))
         (name (config-system-name config))
         (version (or (cl-oci/config:config-version config) "latest"))
         (install-dir (system-install-path name version)))
    (ensure-directories-exist (merge-pathnames "x" install-dir))
    (dolist (layer-desc (manifest-layers manifest))
      (let ((blob (pull-blob registry repository
                             (format-digest (descriptor-digest layer-desc)))))
        (extract-layer blob install-dir)))
    (create-provides-symlinks name (config-provides config))
    (msg "~&Installed ~a ~a to ~a~%" name version install-dir)
    install-dir))

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

(defun install-from-ocicl-manifest (registry repository manifest reference)
  "Install from an OCICL-format manifest. Skips empty config, strips tarball prefix."
  (let* ((layers (manifest-layers manifest))
         (layer-desc (first layers))
         (ann (when layer-desc (descriptor-annotations layer-desc)))
         (title (when ann (gethash +ann-title+ ann))))
    (multiple-value-bind (name version strip-prefix)
        (parse-ocicl-layer-info title)
      (let* ((name (or name (let ((pos (position #\/ repository :from-end t)))
                                (if pos (subseq repository (1+ pos)) repository))))
             (version (or version reference))
             (install-dir (system-install-path name version)))
        (ensure-directories-exist (merge-pathnames "x" install-dir))
        (dolist (ld layers)
          (let ((blob (pull-blob registry repository
                                 (format-digest (descriptor-digest ld)))))
            (if strip-prefix
                (extract-layer-stripping-prefix blob install-dir strip-prefix)
                (extract-layer blob install-dir))))
        (msg "~&Installed ~a ~a to ~a (ocicl)~%" name version install-dir)
        install-dir))))

(defun extract-layer-stripping-prefix (tar-gz-data target-dir prefix)
  "Extract a tar+gzip layer to TARGET-DIR, stripping PREFIX from entry names."
  (let ((input (flexi-streams:make-in-memory-input-stream tar-gz-data)))
    (let ((decompressed (chipz:make-decompressing-stream 'chipz:gzip input)))
      (extract-tar-stream decompressed target-dir :strip-prefix prefix)
      (close decompressed))))

(defun create-provides-symlinks (canonical-name provides)
  "Create symlinks for provided system names that differ from the canonical name.
   E.g., systems/cffi-toolchain -> systems/cffi"
  (when provides
    (let ((canonical-dir (merge-pathnames (format nil "~a/" canonical-name) *systems-root*)))
      (dolist (provided provides)
        (unless (string= provided canonical-name)
          (let ((link-path (merge-pathnames (format nil "~a" provided) *systems-root*)))
            (unless (probe-file link-path)
              (handler-case
                  (progn
                    (ensure-directories-exist *systems-root*)
                    ;; Use uiop for portable symlink creation
                    #+sbcl (sb-posix:symlink (namestring canonical-dir) (namestring link-path))
                    #+(and (not sbcl) unix)
                    (uiop:run-program (list "ln" "-s" (namestring canonical-dir) (namestring link-path)))
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
  (let ((input (flexi-streams:make-in-memory-input-stream tar-gz-data)))
    (let ((decompressed (chipz:make-decompressing-stream 'chipz:gzip input)))
      (extract-tar-stream decompressed target-dir)
      (close decompressed))))

(defun extract-tar-stream (stream target-dir &key strip-prefix)
  "Extract tar entries from STREAM to TARGET-DIR.
   When STRIP-PREFIX is given, remove that prefix from each entry name."
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
  (let ((blocks (ceiling size 512)))
    (dotimes (i blocks)
      (let ((buf (make-array 512 :element-type '(unsigned-byte 8))))
        (read-sequence buf stream)))))

(defun parse-tar-name (header)
  (let ((end (or (position 0 header :end 100) 100)))
    (babel:octets-to-string (subseq header 0 end) :encoding :utf-8)))

(defun parse-tar-size (header)
  (let* ((str (babel:octets-to-string (subseq header 124 136) :encoding :ascii))
         (trimmed (string-trim '(#\Space #\Null) str)))
    (if (zerop (length trimmed)) 0 (parse-integer trimmed :radix 8))))

(defun generate-init-file (install-dir config)
  "Generate cl-repo-init.lisp for CFFI integration."
  (let ((init-path (merge-pathnames "cl-repo-init.lisp" install-dir)))
    (with-open-file (out init-path :direction :output :if-exists :supersede)
      (format out ";;; Auto-generated by cl-repository-client. Do not edit.~%")
      (format out "(in-package :cl-user)~%~%")
      (format out "(when (find-package :cffi)~%")
      (format out "  (pushnew (merge-pathnames \"native/\" ~s)~%"
              (namestring install-dir))
      (format out "           (symbol-value (find-symbol \"*FOREIGN-LIBRARY-DIRECTORIES*\" :cffi))~%")
      (format out "           :test #'equal))~%"))))
