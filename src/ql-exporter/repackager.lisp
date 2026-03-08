(defpackage :cl-repository-ql-exporter/repackager
  (:use :cl)
  (:import-from :babel #:string-to-octets)
  (:import-from :cl-oci/digest #:compute-digest #:format-digest)
  (:import-from :cl-oci/descriptor #:make-descriptor)
  (:import-from :cl-oci/config #:make-cl-system-config #:config-layer-roles #:+role-source+)
  (:import-from :cl-oci/media-types
                #:+oci-image-manifest-v1+ #:+oci-image-index-v1+
                #:+oci-image-layer-tar-gzip+ #:+cl-system-config-v1+
                #:+cl-system-artifact-type+)
  (:import-from :cl-oci/annotations
                #:+ann-title+ #:+ann-version+ #:+ann-licenses+ #:+ann-description+
                #:+ann-created+ #:+ann-authors+ #:+cl-has-native-deps+ #:+cl-cffi-libraries+
                #:+cl-system-name+ #:+cl-depends-on+)
  (:import-from :cl-oci/serialization #:to-json-string)
  (:import-from :cl-oci/manifest #:make-manifest)
  (:import-from :cl-oci/image-index #:make-image-index)
  (:import-from :cl-repository-ql-exporter/dist-parser
                #:ql-release #:ql-release-project #:ql-release-prefix
                #:ql-system #:ql-system-system-name #:ql-system-dependencies)
  (:import-from :cl-repository-ql-exporter/asd-introspector
                #:asd-metadata #:asd-metadata-name #:asd-metadata-version
                #:asd-metadata-description #:asd-metadata-author #:asd-metadata-license
                #:asd-metadata-depends-on #:asd-metadata-has-cffi-p #:extract-asd-metadata)
  (:export #:repackage-result
           #:repackage-result-index-json
           #:repackage-result-index-digest
           #:repackage-result-index-size
           #:repackage-result-blobs
           #:repackage-result-manifest-json
           #:repackage-result-manifest-digest
           #:repackage-project))
(in-package :cl-repository-ql-exporter/repackager)

(defclass repackage-result ()
  ((index-json :type string :initarg :index-json :accessor repackage-result-index-json)
   (index-digest :type string :initarg :index-digest :accessor repackage-result-index-digest)
   (index-size :type integer :initarg :index-size :accessor repackage-result-index-size)
   (manifest-json :type string :initarg :manifest-json :accessor repackage-result-manifest-json)
   (manifest-digest :type string :initarg :manifest-digest :accessor repackage-result-manifest-digest)
   (blobs :type list :initarg :blobs :accessor repackage-result-blobs
          :documentation "Alist of (digest-string . octet-vector)")))

(defun format-iso-time ()
  (multiple-value-bind (sec min hr day mon yr)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ" yr mon day hr min sec)))

(defun repackage-project (source-tar-gz-data release systems &key version)
  "Repackage a Quicklisp project archive into OCI artifacts.
   SOURCE-TAR-GZ-DATA is the raw .tgz bytes from Quicklisp.
   RELEASE is a ql-release. SYSTEMS is a list of ql-system for this project.
   Returns a REPACKAGE-RESULT."
  (let* ((project-name (ql-release-project release))
         (all-deps (remove-duplicates
                    (loop for sys in systems
                          append (ql-system-dependencies sys))
                    :test #'string=))
         (provides (mapcar #'ql-system-system-name systems))
         ;; The source tar.gz IS the layer blob (QL already ships tar.gz)
         (source-digest-obj (compute-digest source-tar-gz-data))
         (source-digest (format-digest source-digest-obj))
         (source-size (length source-tar-gz-data))
         ;; Build config blob
         (cfg (make-cl-system-config :system-name project-name
                                     :version version
                                     :depends-on all-deps
                                     :provides provides))
         (_ (setf (gethash source-digest (config-layer-roles cfg)) +role-source+))
         (cfg-json (to-json-string cfg))
         (cfg-octets (babel:string-to-octets cfg-json :encoding :utf-8))
         (cfg-digest-obj (compute-digest cfg-octets))
         (cfg-digest (format-digest cfg-digest-obj))
         (cfg-size (length cfg-octets))
         ;; Build manifest
         (annotations (make-annotations project-name version all-deps provides))
         (config-desc (make-descriptor :media-type +cl-system-config-v1+
                                       :digest (cl-oci/digest:parse-digest cfg-digest)
                                       :size cfg-size))
         (source-ann (let ((h (make-hash-table :test 'equal)))
                       (setf (gethash +ann-title+ h)
                             (format nil "~a-~a.tar.gz" project-name (or version "latest")))
                       h))
         (source-desc (make-descriptor :media-type +oci-image-layer-tar-gzip+
                                       :digest (cl-oci/digest:parse-digest source-digest)
                                       :size source-size
                                       :annotations source-ann))
         (manifest (make-manifest :config config-desc
                                  :layers (list source-desc)
                                  :artifact-type +cl-system-artifact-type+
                                  :annotations annotations))
         (manifest-json (to-json-string manifest))
         (manifest-octets (babel:string-to-octets manifest-json :encoding :utf-8))
         (manifest-digest (format-digest (compute-digest manifest-octets)))
         (manifest-size (length manifest-octets))
         ;; Build image index
         (manifest-desc (make-descriptor :media-type +oci-image-manifest-v1+
                                         :digest (cl-oci/digest:parse-digest manifest-digest)
                                         :size manifest-size))
         (idx (make-image-index :manifests (list manifest-desc) :annotations annotations))
         (idx-json (to-json-string idx))
         (idx-octets (babel:string-to-octets idx-json :encoding :utf-8))
         (idx-digest (format-digest (compute-digest idx-octets)))
         (idx-size (length idx-octets)))
    (declare (ignore _))
    (make-instance 'repackage-result
                   :index-json idx-json
                   :index-digest idx-digest
                   :index-size idx-size
                   :manifest-json manifest-json
                   :manifest-digest manifest-digest
                   :blobs (list (cons source-digest source-tar-gz-data)
                                (cons cfg-digest cfg-octets)))))

(defun make-annotations (name version deps provides)
  "Build OCI annotation hash-table for a project."
  (let ((ann (make-hash-table :test 'equal)))
    (setf (gethash +ann-title+ ann) name)
    (when version (setf (gethash +ann-version+ ann) version))
    (setf (gethash +ann-created+ ann) (format-iso-time))
    (setf (gethash +cl-system-name+ ann) name)
    (when deps (setf (gethash +cl-depends-on+ ann) (format nil "~{~a~^,~}" deps)))
    (when provides
      (setf (gethash "dev.common-lisp.system.provides" ann)
            (format nil "~{~a~^,~}" provides)))
    ann))
