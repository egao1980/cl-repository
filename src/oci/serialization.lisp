(defpackage :cl-oci/serialization
  (:use :cl)
  (:import-from :yason)
  (:import-from :babel #:string-to-octets)
  (:import-from :alexandria #:when-let)
  (:import-from :cl-oci/conditions #:oci-parse-error)
  (:import-from :cl-oci/digest #:digest #:digest-algorithm #:digest-hex
                #:make-oci-digest #:parse-digest #:format-digest)
  (:import-from :cl-oci/platform #:platform #:platform-os #:platform-architecture
                #:platform-os-version #:platform-os-features #:platform-variant
                #:make-platform)
  (:import-from :cl-oci/descriptor #:descriptor #:descriptor-media-type #:descriptor-digest
                #:descriptor-size #:descriptor-urls #:descriptor-annotations
                #:descriptor-data #:descriptor-artifact-type #:descriptor-platform
                #:make-descriptor)
  (:import-from :cl-oci/manifest #:manifest #:manifest-schema-version #:manifest-media-type
                #:manifest-artifact-type #:manifest-config #:manifest-layers
                #:manifest-subject #:manifest-annotations #:make-manifest)
  (:import-from :cl-oci/image-index #:image-index #:image-index-schema-version
                #:image-index-media-type #:image-index-artifact-type
                #:image-index-manifests #:image-index-subject #:image-index-annotations
                #:make-image-index)
  (:import-from :cl-oci/config #:cl-system-config #:config-system-name #:config-version
                #:config-depends-on #:config-provides #:config-layer-roles
                #:config-cffi-libraries #:config-grovel-systems #:config-build-requires
                #:make-cl-system-config)
  (:export #:to-json
           #:to-json-string
           #:from-json
           #:from-json-string
           #:serialize-to-octets))
(in-package :cl-oci/serialization)

;;; --- Helpers ---

(defun hash-table-from-alist (alist)
  (let ((ht (make-hash-table :test 'equal)))
    (dolist (pair alist ht)
      (setf (gethash (car pair) ht) (cdr pair)))))

(defun hash-table-to-alist (ht)
  (when ht
    (let (result)
      (maphash (lambda (k v) (push (cons k v) result)) ht)
      (nreverse result))))

(defun non-empty-hash-p (ht)
  (and ht (plusp (hash-table-count ht))))

;;; --- To JSON (object -> nested hash-tables/lists for yason) ---

(defgeneric to-json-value (object)
  (:documentation "Convert an OCI object to a JSON-serializable value (hash-tables, lists, strings, numbers)."))

(defmethod to-json-value ((d digest))
  (format-digest d))

(defmethod to-json-value ((p platform))
  (let ((ht (make-hash-table :test 'equal)))
    (when (platform-os p) (setf (gethash "os" ht) (platform-os p)))
    (when (platform-architecture p) (setf (gethash "architecture" ht) (platform-architecture p)))
    (when (platform-os-version p) (setf (gethash "os.version" ht) (platform-os-version p)))
    (when (platform-os-features p)
      (setf (gethash "os.features" ht) (coerce (platform-os-features p) 'vector)))
    (when (platform-variant p) (setf (gethash "variant" ht) (platform-variant p)))
    ht))

(defmethod to-json-value ((d descriptor))
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "mediaType" ht) (descriptor-media-type d))
    (setf (gethash "digest" ht) (format-digest (descriptor-digest d)))
    (setf (gethash "size" ht) (descriptor-size d))
    (when (descriptor-urls d)
      (setf (gethash "urls" ht) (coerce (descriptor-urls d) 'vector)))
    (when (non-empty-hash-p (descriptor-annotations d))
      (setf (gethash "annotations" ht) (descriptor-annotations d)))
    (when (descriptor-artifact-type d)
      (setf (gethash "artifactType" ht) (descriptor-artifact-type d)))
    (when (descriptor-platform d)
      (setf (gethash "platform" ht) (to-json-value (descriptor-platform d))))
    ht))

(defmethod to-json-value ((m manifest))
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "schemaVersion" ht) (manifest-schema-version m))
    (setf (gethash "mediaType" ht) (manifest-media-type m))
    (when (manifest-artifact-type m)
      (setf (gethash "artifactType" ht) (manifest-artifact-type m)))
    (setf (gethash "config" ht) (to-json-value (manifest-config m)))
    (setf (gethash "layers" ht) (map 'vector #'to-json-value (manifest-layers m)))
    (when (manifest-subject m)
      (setf (gethash "subject" ht) (to-json-value (manifest-subject m))))
    (when (non-empty-hash-p (manifest-annotations m))
      (setf (gethash "annotations" ht) (manifest-annotations m)))
    ht))

(defmethod to-json-value ((idx image-index))
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "schemaVersion" ht) (image-index-schema-version idx))
    (setf (gethash "mediaType" ht) (image-index-media-type idx))
    (when (image-index-artifact-type idx)
      (setf (gethash "artifactType" ht) (image-index-artifact-type idx)))
    (setf (gethash "manifests" ht) (map 'vector #'to-json-value (image-index-manifests idx)))
    (when (image-index-subject idx)
      (setf (gethash "subject" ht) (to-json-value (image-index-subject idx))))
    (when (non-empty-hash-p (image-index-annotations idx))
      (setf (gethash "annotations" ht) (image-index-annotations idx)))
    ht))

(defmethod to-json-value ((cfg cl-system-config))
  (let ((ht (make-hash-table :test 'equal)))
    (setf (gethash "system-name" ht) (config-system-name cfg))
    (when (config-version cfg) (setf (gethash "version" ht) (config-version cfg)))
    (when (config-depends-on cfg)
      (setf (gethash "depends-on" ht) (coerce (config-depends-on cfg) 'vector)))
    (when (config-provides cfg)
      (setf (gethash "provides" ht) (coerce (config-provides cfg) 'vector)))
    (when (non-empty-hash-p (config-layer-roles cfg))
      (setf (gethash "layer-roles" ht) (config-layer-roles cfg)))
    (when (config-cffi-libraries cfg)
      (setf (gethash "cffi-libraries" ht) (config-cffi-libraries cfg)))
    (when (config-grovel-systems cfg)
      (setf (gethash "grovel-systems" ht) (coerce (config-grovel-systems cfg) 'vector)))
    (when (config-build-requires cfg)
      (setf (gethash "build-requires" ht) (config-build-requires cfg)))
    ht))

;;; --- Serialization to JSON string / octets ---

(defun to-json (object &key (stream nil) (pretty nil))
  "Serialize an OCI object to JSON. Returns string if STREAM is NIL."
  (declare (ignore pretty))
  (let ((value (to-json-value object)))
    (if stream
        (yason:encode value stream)
        (with-output-to-string (s) (yason:encode value s)))))

(defun to-json-string (object &key (pretty nil))
  "Serialize an OCI object to a JSON string."
  (declare (ignore pretty))
  (with-output-to-string (s) (yason:encode (to-json-value object) s)))

(defun serialize-to-octets (object)
  "Serialize an OCI object to a UTF-8 octet vector."
  (babel:string-to-octets (to-json-string object) :encoding :utf-8))

;;; --- From JSON (parse JSON -> OCI objects) ---

(defun parse-json-string (string)
  (yason:parse string))

(defun gethash* (key ht &optional default)
  "Get from hash-table, returning DEFAULT if HT is nil."
  (if ht (gethash key ht default) default))

(defun parse-annotations (ht)
  "Extract annotations hash-table, or return empty one."
  (or (gethash* "annotations" ht) (make-hash-table :test 'equal)))

(defun parse-platform-from-json (ht)
  (when ht
    (make-platform :os (gethash* "os" ht)
                   :architecture (gethash* "architecture" ht)
                   :os-version (gethash* "os.version" ht)
                   :os-features (when-let ((f (gethash* "os.features" ht)))
                                  (coerce f 'list))
                   :variant (gethash* "variant" ht))))

(defun parse-descriptor-from-json (ht)
  (when ht
    (make-descriptor :media-type (gethash "mediaType" ht)
                     :digest (parse-digest (gethash "digest" ht))
                     :size (gethash "size" ht)
                     :urls (when-let ((u (gethash* "urls" ht))) (coerce u 'list))
                     :annotations (parse-annotations ht)
                     :artifact-type (gethash* "artifactType" ht)
                     :platform (parse-platform-from-json (gethash* "platform" ht)))))

(defun parse-manifest-from-json (ht)
  (make-manifest :schema-version (gethash "schemaVersion" ht)
                 :media-type (gethash "mediaType" ht)
                 :artifact-type (gethash* "artifactType" ht)
                 :config (parse-descriptor-from-json (gethash "config" ht))
                 :layers (map 'list #'parse-descriptor-from-json
                              (gethash "layers" ht))
                 :subject (parse-descriptor-from-json (gethash* "subject" ht))
                 :annotations (parse-annotations ht)))

(defun parse-image-index-from-json (ht)
  (make-image-index :schema-version (gethash "schemaVersion" ht)
                    :media-type (gethash "mediaType" ht)
                    :artifact-type (gethash* "artifactType" ht)
                    :manifests (map 'list #'parse-descriptor-from-json
                                    (gethash "manifests" ht))
                    :subject (parse-descriptor-from-json (gethash* "subject" ht))
                    :annotations (parse-annotations ht)))

(defun parse-cl-system-config-from-json (ht)
  (make-cl-system-config
   :system-name (gethash "system-name" ht)
   :version (gethash* "version" ht)
   :depends-on (when-let ((d (gethash* "depends-on" ht))) (coerce d 'list))
   :provides (when-let ((p (gethash* "provides" ht))) (coerce p 'list))
   :layer-roles (or (gethash* "layer-roles" ht) (make-hash-table :test 'equal))
   :cffi-libraries (gethash* "cffi-libraries" ht)
   :grovel-systems (when-let ((g (gethash* "grovel-systems" ht))) (coerce g 'list))
   :build-requires (gethash* "build-requires" ht)))

(defun from-json (class json-source)
  "Parse JSON-SOURCE (string or hash-table) into an instance of CLASS.
   CLASS is a symbol naming the class: manifest, image-index, descriptor, platform, cl-system-config."
  (let ((ht (etypecase json-source
              (hash-table json-source)
              (string (parse-json-string json-source))))
        (name (string class)))
    (cond
      ((string-equal name "MANIFEST") (parse-manifest-from-json ht))
      ((string-equal name "IMAGE-INDEX") (parse-image-index-from-json ht))
      ((string-equal name "DESCRIPTOR") (parse-descriptor-from-json ht))
      ((string-equal name "PLATFORM") (parse-platform-from-json ht))
      ((string-equal name "CL-SYSTEM-CONFIG") (parse-cl-system-config-from-json ht))
      (t (error "Unknown OCI class: ~a" class)))))

(defun from-json-string (class string)
  "Parse a JSON STRING into an instance of CLASS."
  (from-json class string))
