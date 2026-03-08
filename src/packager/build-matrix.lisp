(defpackage :cl-repository-packager/build-matrix
  (:use :cl)
  (:import-from :cl-oci/platform #:make-platform)
  (:import-from :cl-oci/annotations
                #:+ann-title+ #:+ann-version+ #:+ann-licenses+ #:+ann-description+
                #:+ann-created+ #:+ann-authors+ #:+cl-implementation+ #:+cl-layer-roles+
                #:+cl-depends-on+ #:+cl-depends-on-versioned+ #:+cl-provides+)
  (:import-from :cl-oci/config #:+role-source+ #:+role-native-library+
                #:+role-cffi-grovel-output+ #:+role-cffi-wrapper+ #:+role-headers+
                #:+role-documentation+)
  (:import-from :cl-repository-packager/layer-builder
                #:build-layer-from-directory #:build-layer-from-files
                #:layer-result #:layer-result-data #:layer-result-digest
                #:layer-result-size #:layer-result-role #:layer-result-title)
  (:import-from :cl-repository-packager/manifest-builder
                #:build-config-blob #:build-manifest-for-layers #:build-image-index
                #:built-manifest #:built-manifest-descriptor)
  (:export #:package-spec
           #:define-package-spec
           #:package-spec-name
           #:package-spec-version
           #:package-spec-source-dir
           #:package-spec-description
           #:package-spec-depends-on
           #:package-spec-provides
           #:package-spec-overlays
           #:overlay-spec
           #:overlay-spec-os
           #:overlay-spec-arch
           #:overlay-spec-os-version
           #:overlay-spec-lisp
           #:overlay-spec-native-paths
           #:parse-overlay-spec
           #:build-package
           #:build-overlay
           #:overlay-result
           #:overlay-result-blobs
           #:overlay-result-manifest
           #:build-result
           #:build-result-index-json
           #:build-result-index-digest
           #:build-result-blobs
           #:build-result-manifests))
(in-package :cl-repository-packager/build-matrix)

(defclass package-spec ()
  ((name :type string :initarg :name :accessor package-spec-name)
   (version :type (or null string) :initarg :version :accessor package-spec-version :initform nil)
   (source-dir :type pathname :initarg :source-dir :accessor package-spec-source-dir)
   (license :type (or null string) :initarg :license :accessor package-spec-license :initform nil)
   (description :type (or null string) :initarg :description :accessor package-spec-description
                :initform nil)
   (author :type (or null string) :initarg :author :accessor package-spec-author :initform nil)
   (depends-on :type list :initarg :depends-on :accessor package-spec-depends-on :initform nil)
   (provides :type list :initarg :provides :accessor package-spec-provides :initform nil)
   (cffi-libraries :type list :initarg :cffi-libraries :accessor package-spec-cffi-libraries
                   :initform nil)
   (grovel-systems :type list :initarg :grovel-systems :accessor package-spec-grovel-systems
                   :initform nil)
   (header-paths :type list :initarg :header-paths :accessor package-spec-header-paths :initform nil)
   (build-requires :type list :initarg :build-requires :accessor package-spec-build-requires
                   :initform nil)
   (overlays :type list :initarg :overlays :accessor package-spec-overlays :initform nil)))

(defclass overlay-spec ()
  ((platform-os :type string :initarg :os :accessor overlay-spec-os)
   (platform-arch :type string :initarg :arch :accessor overlay-spec-arch)
   (platform-os-version :type (or null string) :initarg :os-version :accessor overlay-spec-os-version
                        :initform nil)
   (lisp :type (or null string) :initarg :lisp :accessor overlay-spec-lisp :initform nil)
   (native-paths :type list :initarg :native-paths :accessor overlay-spec-native-paths :initform nil)
   (run-groveler :type boolean :initarg :run-groveler :accessor overlay-spec-run-groveler
                 :initform nil)
   (cffi-wrapper-systems :type list :initarg :cffi-wrapper-systems
                         :accessor overlay-spec-cffi-wrapper-systems :initform nil)))

(defclass build-result ()
  ((index-json :type string :initarg :index-json :accessor build-result-index-json)
   (index-digest :type string :initarg :index-digest :accessor build-result-index-digest)
   (blobs :type list :initarg :blobs :accessor build-result-blobs)
   (manifests :type list :initarg :manifests :accessor build-result-manifests)))

(defclass overlay-result ()
  ((blobs :type list :initarg :blobs :accessor overlay-result-blobs
          :documentation "List of (digest . octets) pairs for the overlay.")
   (manifest :type built-manifest :initarg :manifest :accessor overlay-result-manifest
             :documentation "The built overlay manifest.")))

(defun dep-flat-name (dep)
  "Extract flat name from a dependency (string or cons)."
  (etypecase dep
    (string dep)
    (cons (car dep))))

(defun dep-versioned-string (dep)
  "Format a dependency with version constraint: \"name\" or \"name@>=ver\"."
  (etypecase dep
    (string dep)
    (cons (format nil "~a@>=~a" (car dep) (cdr dep)))))

(defun make-annotations (spec)
  "Build OCI annotation hash-table from a package-spec."
  (let ((ann (make-hash-table :test 'equal)))
    (setf (gethash +ann-title+ ann) (package-spec-name spec))
    (when (package-spec-version spec) (setf (gethash +ann-version+ ann) (package-spec-version spec)))
    (when (package-spec-license spec) (setf (gethash +ann-licenses+ ann) (package-spec-license spec)))
    (when (package-spec-description spec)
      (setf (gethash +ann-description+ ann) (package-spec-description spec)))
    (when (package-spec-author spec) (setf (gethash +ann-authors+ ann) (package-spec-author spec)))
    (setf (gethash +ann-created+ ann) (format-iso-time))
    (when (package-spec-depends-on spec)
      (setf (gethash +cl-depends-on+ ann)
            (format nil "~{~a~^,~}" (mapcar #'dep-flat-name (package-spec-depends-on spec))))
      (setf (gethash +cl-depends-on-versioned+ ann)
            (format nil "~{~a~^,~}" (mapcar #'dep-versioned-string (package-spec-depends-on spec)))))
    (when (package-spec-provides spec)
      (setf (gethash +cl-provides+ ann)
            (format nil "~{~a~^,~}" (package-spec-provides spec))))
    ann))

(defun format-iso-time ()
  (multiple-value-bind (sec min hr day mon yr)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ" yr mon day hr min sec)))

(defun parse-overlay-spec (plist)
  "Parse an overlay spec from a plist like (:platform (:os \"linux\" :arch \"amd64\") ...)."
  (let ((plat (getf plist :platform)))
    (make-instance 'overlay-spec
                   :os (getf plat :os)
                   :arch (getf plat :arch)
                   :os-version (getf plat :os-version)
                   :lisp (getf plat :lisp)
                   :native-paths (getf plist :native-paths)
                   :run-groveler (getf plist :run-groveler)
                   :cffi-wrapper-systems (getf plist :cffi-wrapper-systems))))

(defmacro define-package-spec (name &rest args)
  "Define a package specification for OCI packaging."
  `(make-instance 'package-spec
                  :name ,name
                  :version ,(getf args :version)
                  :source-dir ,(or (getf args :source-dir) `(uiop:getcwd))
                  :license ,(getf args :license)
                  :description ,(getf args :description)
                  :author ,(getf args :author)
                  :depends-on (list ,@(getf args :depends-on))
                  :provides (list ,@(getf args :provides))
                  :cffi-libraries ',(getf args :cffi-libraries)
                  :grovel-systems (list ,@(getf args :grovel-systems))
                  :header-paths (list ,@(getf args :header-paths))
                  :build-requires ',(getf args :build-requires)
                  :overlays (mapcar #'parse-overlay-spec ',(getf args :overlays))))

(defun build-package (spec)
  "Build a complete OCI package from SPEC. Returns a BUILD-RESULT."
  (let ((all-blobs nil)
        (all-manifests nil)
        (manifest-descriptors nil)
        (ann (make-annotations spec)))
    ;; 1. Build source layer (with OCICL-compatible root directory prefix)
    (let* ((tar-prefix (format nil "~a-~a/"
                               (package-spec-name spec)
                               (or (package-spec-version spec) "latest")))
           (source-layer (build-layer-from-directory
                          (package-spec-source-dir spec) +role-source+
                          :tar-prefix tar-prefix)))
      (setf (layer-result-title source-layer)
            (format nil "~a-~a.tar.gz"
                    (package-spec-name spec)
                    (or (package-spec-version spec) "latest")))
      (push (cons (layer-result-digest source-layer) (layer-result-data source-layer)) all-blobs)
      ;; 2. Build universal config + manifest
      (multiple-value-bind (cfg-octets cfg-digest cfg-size)
          (build-config-blob (package-spec-name spec)
                             :version (package-spec-version spec)
                             :depends-on (package-spec-depends-on spec)
                             :provides (package-spec-provides spec)
                             :layers (list source-layer)
                             :cffi-libraries (package-spec-cffi-libraries spec)
                             :grovel-systems (package-spec-grovel-systems spec)
                             :build-requires (package-spec-build-requires spec))
        (push (cons cfg-digest cfg-octets) all-blobs)
        (let ((bm (build-manifest-for-layers cfg-octets cfg-digest cfg-size
                                             (list source-layer)
                                             :annotations ann)))
          (push bm all-manifests)
          (push (built-manifest-descriptor bm) manifest-descriptors)))
      ;; 3. Build overlay manifests for each platform
      ;; Each overlay includes the source layer so that standard OCI clients
      ;; (oras pull --platform linux/amd64) get a complete, self-contained artifact.
      ;; The source blob is content-addressable -- the registry stores it once.
      (dolist (overlay (package-spec-overlays spec))
        (let ((overlay-layers nil)
              (plat (make-platform :os (overlay-spec-os overlay)
                                   :architecture (overlay-spec-arch overlay)
                                   :os-version (overlay-spec-os-version overlay))))
          ;; Source layer first (same blob as universal, deduped by registry)
          (push source-layer overlay-layers)
          ;; Native library layer (prefixed so tar overlays cleanly on source)
          (when (overlay-spec-native-paths overlay)
            (let* ((pairs (mapcar (lambda (p)
                                    (let ((path (merge-pathnames p (package-spec-source-dir spec))))
                                      (cons (file-namestring path) path)))
                                  (overlay-spec-native-paths overlay)))
                   (layer (build-layer-from-files pairs +role-native-library+
                                                  :tar-prefix (concatenate 'string tar-prefix "native/"))))
              (push layer overlay-layers)
              (push (cons (layer-result-digest layer) (layer-result-data layer)) all-blobs)))
          ;; Build overlay config + manifest
          (setf overlay-layers (nreverse overlay-layers))
          (multiple-value-bind (cfg-octets cfg-digest cfg-size)
              (build-config-blob (package-spec-name spec)
                                 :version (package-spec-version spec)
                                 :depends-on (package-spec-depends-on spec)
                                 :provides (package-spec-provides spec)
                                 :layers overlay-layers
                                 :cffi-libraries (package-spec-cffi-libraries spec))
            (push (cons cfg-digest cfg-octets) all-blobs)
            (let* ((overlay-ann (make-hash-table :test 'equal))
                   (_ (when (overlay-spec-lisp overlay)
                        (setf (gethash +cl-implementation+ overlay-ann)
                              (overlay-spec-lisp overlay))))
                   (roles (format nil "~{~a~^,~}" (mapcar #'layer-result-role overlay-layers)))
                   (_2 (setf (gethash +cl-layer-roles+ overlay-ann) roles))
                   (bm (build-manifest-for-layers cfg-octets cfg-digest cfg-size
                                                  overlay-layers
                                                  :annotations overlay-ann
                                                  :platform plat)))
              (declare (ignore _ _2))
              (push bm all-manifests)
              (push (built-manifest-descriptor bm) manifest-descriptors)))))
      ;; 4. Build Image Index
      (multiple-value-bind (idx-json idx-digest idx-size)
          (build-image-index (nreverse manifest-descriptors) :annotations ann)
        (declare (ignore idx-size))
        (make-instance 'build-result
                       :index-json idx-json
                       :index-digest idx-digest
                       :blobs (nreverse all-blobs)
                       :manifests (nreverse all-manifests))))))

(defun build-overlay (system-name overlay &key version source-layer)
  "Build a single platform overlay without the universal manifest.
   OVERLAY is an overlay-spec. SOURCE-LAYER, when provided, is a layer-result
   for the source layer to include in the overlay manifest for OCI client
   compatibility (the blob is already in the registry, no re-upload needed).
   Returns an OVERLAY-RESULT."
  (let* ((blobs nil)
         (overlay-layers nil)
         (tar-prefix (format nil "~a-~a/" system-name (or version "latest")))
         (plat (make-platform :os (overlay-spec-os overlay)
                              :architecture (overlay-spec-arch overlay)
                              :os-version (overlay-spec-os-version overlay))))
    ;; Source layer first (if available) for OCI client compat
    (when source-layer
      (push source-layer overlay-layers))
    (when (overlay-spec-native-paths overlay)
      (let* ((pairs (mapcar (lambda (p)
                              (let ((path (if (pathnamep p) p (pathname p))))
                                (cons (file-namestring path) path)))
                            (overlay-spec-native-paths overlay)))
             (layer (build-layer-from-files pairs +role-native-library+
                                            :tar-prefix (concatenate 'string tar-prefix "native/"))))
        (push layer overlay-layers)
        (push (cons (layer-result-digest layer) (layer-result-data layer)) blobs)))
    (let ((real-layers (if source-layer
                           (nreverse overlay-layers)
                           (progn
                             (unless overlay-layers
                               (error "Overlay for ~a/~a has no layers to build."
                                      (overlay-spec-os overlay) (overlay-spec-arch overlay)))
                             (nreverse overlay-layers)))))
      (multiple-value-bind (cfg-octets cfg-digest cfg-size)
          (build-config-blob system-name :version version :layers real-layers)
        (push (cons cfg-digest cfg-octets) blobs)
        (let* ((overlay-ann (make-hash-table :test 'equal))
               (_ (when (overlay-spec-lisp overlay)
                    (setf (gethash +cl-implementation+ overlay-ann)
                          (overlay-spec-lisp overlay))))
               (roles (format nil "~{~a~^,~}" (mapcar #'layer-result-role real-layers)))
               (_2 (setf (gethash +cl-layer-roles+ overlay-ann) roles))
               (bm (build-manifest-for-layers cfg-octets cfg-digest cfg-size
                                              real-layers
                                              :annotations overlay-ann
                                              :platform plat)))
          (declare (ignore _ _2))
          (make-instance 'overlay-result
                         :blobs (nreverse blobs)
                         :manifest bm))))))
