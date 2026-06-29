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

(defmacro json-object (&body entries)
  "Build an EQUAL hash-table for yason from ENTRIES.
Each ENTRY is (KEY VALUE) to set unconditionally, or (KEY VALUE :when TEST)
to set KEY only when TEST holds (TEST is evaluated first, VALUE only if it passes)."
  (let ((ht (gensym "JSON")))
    `(let ((,ht (make-hash-table :test 'equal)))
       ,@(loop for (key value . opts) in entries
               for test = (if opts (getf opts :when) t)
               collect (if (eq test t)
                           `(setf (gethash ,key ,ht) ,value)
                           `(when ,test (setf (gethash ,key ,ht) ,value))))
       ,ht)))

;;; --- To JSON (object -> nested hash-tables/lists for yason) ---

(defgeneric to-json-value (object)
  (:documentation "Convert an OCI object to a JSON-serializable value (hash-tables, lists, strings, numbers)."))

(defmethod to-json-value ((d digest))
  (format-digest d))

(defmethod to-json-value ((p platform))
  (json-object
    ("os" (platform-os p) :when (platform-os p))
    ("architecture" (platform-architecture p) :when (platform-architecture p))
    ("os.version" (platform-os-version p) :when (platform-os-version p))
    ("os.features" (coerce (platform-os-features p) 'vector) :when (platform-os-features p))
    ("variant" (platform-variant p) :when (platform-variant p))))

(defmethod to-json-value ((d descriptor))
  (json-object
    ("mediaType" (descriptor-media-type d))
    ("digest" (format-digest (descriptor-digest d)))
    ("size" (descriptor-size d))
    ("urls" (coerce (descriptor-urls d) 'vector) :when (descriptor-urls d))
    ("annotations" (descriptor-annotations d) :when (non-empty-hash-p (descriptor-annotations d)))
    ("artifactType" (descriptor-artifact-type d) :when (descriptor-artifact-type d))
    ("platform" (to-json-value (descriptor-platform d)) :when (descriptor-platform d))))

(defmethod to-json-value ((m manifest))
  (json-object
    ("schemaVersion" (manifest-schema-version m))
    ("mediaType" (manifest-media-type m))
    ("artifactType" (manifest-artifact-type m) :when (manifest-artifact-type m))
    ("config" (to-json-value (manifest-config m)))
    ("layers" (map 'vector #'to-json-value (manifest-layers m)))
    ("subject" (to-json-value (manifest-subject m)) :when (manifest-subject m))
    ("annotations" (manifest-annotations m) :when (non-empty-hash-p (manifest-annotations m)))))

(defmethod to-json-value ((idx image-index))
  (json-object
    ("schemaVersion" (image-index-schema-version idx))
    ("mediaType" (image-index-media-type idx))
    ("artifactType" (image-index-artifact-type idx) :when (image-index-artifact-type idx))
    ("manifests" (map 'vector #'to-json-value (image-index-manifests idx)))
    ("subject" (to-json-value (image-index-subject idx)) :when (image-index-subject idx))
    ("annotations" (image-index-annotations idx) :when (non-empty-hash-p (image-index-annotations idx)))))

(defun serialize-dep (dep)
  "Serialize a dependency: string -> string, (name . version) -> {name, version}."
  (etypecase dep
    (string dep)
    (cons (json-object
            ("name" (car dep))
            ("version" (cdr dep))))))

(defun serialize-cffi-libraries (libs)
  "Canonical alist (NAME . PLIST) -> JSON object
   {NAME: {define-foreign-library, canary, search-path}} (omitting nil fields)."
  (let ((ht (make-hash-table :test 'equal)))
    (dolist (lib libs ht)
      (destructuring-bind (name . plist) lib
        (setf (gethash name ht)
              (json-object
                ("define-foreign-library" (getf plist :define-foreign-library)
                 :when (getf plist :define-foreign-library))
                ("canary" (getf plist :canary) :when (getf plist :canary))
                ("search-path" (getf plist :search-path) :when (getf plist :search-path))))))))

(defmethod to-json-value ((cfg cl-system-config))
  (json-object
    ("system-name" (config-system-name cfg))
    ("version" (config-version cfg) :when (config-version cfg))
    ("depends-on" (coerce (mapcar #'serialize-dep (config-depends-on cfg)) 'vector)
                  :when (config-depends-on cfg))
    ("provides" (coerce (config-provides cfg) 'vector) :when (config-provides cfg))
    ("layer-roles" (config-layer-roles cfg) :when (non-empty-hash-p (config-layer-roles cfg)))
    ("cffi-libraries" (serialize-cffi-libraries (config-cffi-libraries cfg))
                      :when (config-cffi-libraries cfg))
    ("grovel-systems" (coerce (config-grovel-systems cfg) 'vector) :when (config-grovel-systems cfg))
    ("build-requires" (config-build-requires cfg) :when (config-build-requires cfg))))

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

(defun deserialize-dep (dep)
  "Deserialize a dependency: string -> string, {name, version} -> (name . version)."
  (etypecase dep
    (string dep)
    (hash-table (cons (gethash "name" dep) (gethash "version" dep)))))

(defun deserialize-cffi-libraries (value)
  "Parse cffi-libraries JSON -> canonical alist (NAME . PLIST).
   Accepts the object form {NAME: {define-foreign-library, canary, search-path}} and
   the legacy array-of-names form [\"libfoo\"] (parsed by yason as a list)."
  (typecase value
    (null nil)
    (hash-table
     (let (result)
       (maphash
        (lambda (name meta)
          (push (cons name
                      (loop for (json-key plist-key)
                              in '(("define-foreign-library" :define-foreign-library)
                                   ("canary" :canary)
                                   ("search-path" :search-path))
                            for v = (and (hash-table-p meta) (gethash json-key meta))
                            when v append (list plist-key v)))
                result))
        value)
       (nreverse result)))
    (sequence (map 'list (lambda (name) (list name)) value))))

(defun parse-cl-system-config-from-json (ht)
  (make-cl-system-config
   :system-name (gethash "system-name" ht)
   :version (gethash* "version" ht)
   :depends-on (when-let ((d (gethash* "depends-on" ht)))
                 (mapcar #'deserialize-dep (coerce d 'list)))
   :provides (when-let ((p (gethash* "provides" ht))) (coerce p 'list))
   :layer-roles (or (gethash* "layer-roles" ht) (make-hash-table :test 'equal))
   :cffi-libraries (deserialize-cffi-libraries (gethash* "cffi-libraries" ht))
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
