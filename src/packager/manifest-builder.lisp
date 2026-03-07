(defpackage :cl-repository-packager/manifest-builder
  (:use :cl)
  (:import-from :babel #:string-to-octets)
  (:import-from :cl-oci/digest #:compute-digest #:format-digest #:parse-digest)
  (:import-from :cl-oci/descriptor #:make-descriptor)
  (:import-from :cl-oci/platform #:make-platform)
  (:import-from :cl-oci/manifest #:make-manifest #:manifest-annotations)
  (:import-from :cl-oci/image-index #:make-image-index)
  (:import-from :cl-oci/config #:make-cl-system-config #:config-layer-roles)
  (:import-from :cl-oci/media-types
                #:+oci-image-manifest-v1+ #:+oci-image-index-v1+
                #:+oci-image-layer-tar-gzip+ #:+cl-system-config-v1+
                #:+cl-system-artifact-type+ #:+oci-empty-config+)
  (:import-from :cl-oci/annotations
                #:+ann-title+ #:+ann-version+ #:+ann-licenses+ #:+ann-description+
                #:+ann-created+ #:+ann-source+ #:+ann-authors+
                #:+cl-layer-roles+ #:+cl-implementation+)
  (:import-from :cl-oci/serialization #:to-json-string #:serialize-to-octets)
  (:import-from :cl-repository-packager/layer-builder
                #:layer-result #:layer-result-data #:layer-result-digest
                #:layer-result-size #:layer-result-role)
  (:export #:build-config-blob
           #:build-manifest-for-layers
           #:build-image-index
           #:build-anchor-manifest
           #:built-manifest
           #:built-manifest-json
           #:built-manifest-digest
           #:built-manifest-size
           #:built-manifest-descriptor))
(in-package :cl-repository-packager/manifest-builder)

(defclass built-manifest ()
  ((json :type string :initarg :json :accessor built-manifest-json)
   (digest :type string :initarg :digest :accessor built-manifest-digest)
   (size :type integer :initarg :size :accessor built-manifest-size)
   (descriptor :initarg :descriptor :accessor built-manifest-descriptor)))

(defun build-config-blob (system-name &key version depends-on provides layers
                                        cffi-libraries grovel-systems build-requires)
  "Build a CL system config JSON blob. Returns (values json-octets digest-string size)."
  (let ((cfg (make-cl-system-config :system-name system-name
                                    :version version
                                    :depends-on depends-on
                                    :provides provides
                                    :cffi-libraries cffi-libraries
                                    :grovel-systems grovel-systems
                                    :build-requires build-requires)))
    ;; Populate layer-roles from layers
    (when layers
      (dolist (lr layers)
        (setf (gethash (layer-result-digest lr) (config-layer-roles cfg))
              (layer-result-role lr))))
    (let* ((json-str (to-json-string cfg))
           (octets (babel:string-to-octets json-str :encoding :utf-8))
           (digest-obj (compute-digest octets)))
      (values octets (format-digest digest-obj) (length octets)))))

(defun build-manifest-for-layers (config-octets config-digest config-size layers
                                  &key artifact-type annotations platform)
  "Build an OCI manifest from a config blob and layer results. Returns a BUILT-MANIFEST."
  (let* ((config-desc (make-descriptor :media-type +cl-system-config-v1+
                                       :digest (parse-digest config-digest)
                                       :size config-size))
         (layer-descs (mapcar (lambda (lr)
                               (let ((ann (make-hash-table :test 'equal)))
                                 (setf (gethash +ann-title+ ann)
                                       (format nil "~a.tar.gz" (layer-result-role lr)))
                                 (make-descriptor
                                  :media-type +oci-image-layer-tar-gzip+
                                  :digest (parse-digest (layer-result-digest lr))
                                  :size (layer-result-size lr)
                                  :annotations ann)))
                             layers))
         (manifest (make-manifest :config config-desc
                                  :layers layer-descs
                                  :artifact-type (or artifact-type +cl-system-artifact-type+)
                                  :annotations annotations))
         (json-str (to-json-string manifest))
         (json-octets (babel:string-to-octets json-str :encoding :utf-8))
         (manifest-digest (format-digest (compute-digest json-octets)))
         (manifest-size (length json-octets))
         (manifest-desc (make-descriptor :media-type +oci-image-manifest-v1+
                                         :digest (parse-digest manifest-digest)
                                         :size manifest-size
                                         :platform platform)))
    (make-instance 'built-manifest
                   :json json-str
                   :digest manifest-digest
                   :size manifest-size
                   :descriptor manifest-desc)))

(defun build-image-index (manifest-descriptors &key annotations)
  "Build an OCI Image Index from a list of manifest descriptors.
   Returns (values index-json index-digest index-size)."
  (let* ((idx (make-image-index :manifests manifest-descriptors
                                :annotations annotations))
         (json-str (to-json-string idx))
         (json-octets (babel:string-to-octets json-str :encoding :utf-8))
         (digest (format-digest (compute-digest json-octets))))
    (values json-str digest (length json-octets))))

(defun build-anchor-manifest (artifact-type &key annotations config-data subject)
  "Build an empty-layer manifest for anchors and referrers.
   CONFIG-DATA: octets for a config blob, or NIL for empty config.
   SUBJECT: a descriptor pointing to the subject manifest (for referrers).
   Returns a BUILT-MANIFEST."
  (let* ((config-octets (or config-data
                             (babel:string-to-octets "{}" :encoding :utf-8)))
         (config-media-type (if config-data +cl-system-config-v1+ +oci-empty-config+))
         (config-digest-obj (compute-digest config-octets))
         (config-desc (make-descriptor :media-type config-media-type
                                       :digest config-digest-obj
                                       :size (length config-octets)))
         (manifest (make-manifest :config config-desc
                                  :layers nil
                                  :artifact-type artifact-type
                                  :subject subject
                                  :annotations (or annotations (make-hash-table :test 'equal))))
         (json-str (to-json-string manifest))
         (json-octets (babel:string-to-octets json-str :encoding :utf-8))
         (manifest-digest (format-digest (compute-digest json-octets)))
         (manifest-size (length json-octets)))
    (values (make-instance 'built-manifest
                           :json json-str
                           :digest manifest-digest
                           :size manifest-size
                           :descriptor (make-descriptor :media-type +oci-image-manifest-v1+
                                                        :digest (parse-digest manifest-digest)
                                                        :size manifest-size))
            config-octets
            (format-digest config-digest-obj))))
