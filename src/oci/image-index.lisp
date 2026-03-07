(defpackage :cl-oci/image-index
  (:use :cl)
  (:import-from :cl-oci/descriptor #:descriptor)
  (:import-from :cl-oci/media-types #:+oci-image-index-v1+)
  (:export #:image-index
           #:image-index-schema-version
           #:image-index-media-type
           #:image-index-artifact-type
           #:image-index-manifests
           #:image-index-subject
           #:image-index-annotations
           #:make-image-index
           #:image-index-annotation))
(in-package :cl-oci/image-index)

(defclass image-index ()
  ((schema-version :type integer :initarg :schema-version :accessor image-index-schema-version
                   :initform 2)
   (media-type :type string :initarg :media-type :accessor image-index-media-type
               :initform +oci-image-index-v1+)
   (artifact-type :type (or null string) :initarg :artifact-type :accessor image-index-artifact-type
                  :initform nil)
   (manifests :type list :initarg :manifests :accessor image-index-manifests :initform nil)
   (subject :type (or null descriptor) :initarg :subject :accessor image-index-subject :initform nil)
   (annotations :type hash-table :initarg :annotations :accessor image-index-annotations
                :initform (make-hash-table :test 'equal))))

(defun make-image-index (&key (schema-version 2) (media-type +oci-image-index-v1+)
                           artifact-type manifests subject annotations)
  (make-instance 'image-index
                 :schema-version schema-version
                 :media-type media-type
                 :artifact-type artifact-type
                 :manifests (or manifests nil)
                 :subject subject
                 :annotations (or annotations (make-hash-table :test 'equal))))

(defun image-index-annotation (index key &optional default)
  (gethash key (image-index-annotations index) default))

(defun (setf image-index-annotation) (value index key)
  (setf (gethash key (image-index-annotations index)) value))
