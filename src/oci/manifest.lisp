(defpackage :cl-oci/manifest
  (:use :cl)
  (:import-from :cl-oci/descriptor #:descriptor)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+)
  (:export #:manifest
           #:manifest-schema-version
           #:manifest-media-type
           #:manifest-artifact-type
           #:manifest-config
           #:manifest-layers
           #:manifest-subject
           #:manifest-annotations
           #:make-manifest
           #:manifest-annotation))
(in-package :cl-oci/manifest)

(defclass manifest ()
  ((schema-version :type integer :initarg :schema-version :accessor manifest-schema-version :initform 2)
   (media-type :type string :initarg :media-type :accessor manifest-media-type
               :initform +oci-image-manifest-v1+)
   (artifact-type :type (or null string) :initarg :artifact-type :accessor manifest-artifact-type
                  :initform nil)
   (config :type descriptor :initarg :config :accessor manifest-config)
   (layers :type list :initarg :layers :accessor manifest-layers :initform nil)
   (subject :type (or null descriptor) :initarg :subject :accessor manifest-subject :initform nil)
   (annotations :type hash-table :initarg :annotations :accessor manifest-annotations
                :initform (make-hash-table :test 'equal))))

(defun make-manifest (&key (schema-version 2) (media-type +oci-image-manifest-v1+)
                        artifact-type config layers subject annotations)
  (make-instance 'manifest
                 :schema-version schema-version
                 :media-type media-type
                 :artifact-type artifact-type
                 :config config
                 :layers (or layers nil)
                 :subject subject
                 :annotations (or annotations (make-hash-table :test 'equal))))

(defun manifest-annotation (manifest key &optional default)
  (gethash key (manifest-annotations manifest) default))

(defun (setf manifest-annotation) (value manifest key)
  (setf (gethash key (manifest-annotations manifest)) value))
