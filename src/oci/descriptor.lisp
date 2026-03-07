(defpackage :cl-oci/descriptor
  (:use :cl)
  (:import-from :cl-oci/digest #:digest #:format-digest #:parse-digest)
  (:import-from :cl-oci/platform #:platform)
  (:export #:descriptor
           #:descriptor-media-type
           #:descriptor-digest
           #:descriptor-size
           #:descriptor-urls
           #:descriptor-annotations
           #:descriptor-data
           #:descriptor-artifact-type
           #:descriptor-platform
           #:make-descriptor
           #:descriptor-annotation))
(in-package :cl-oci/descriptor)

(defclass descriptor ()
  ((media-type :type string :initarg :media-type :accessor descriptor-media-type)
   (digest :type digest :initarg :digest :accessor descriptor-digest)
   (size :type integer :initarg :size :accessor descriptor-size)
   (urls :type list :initarg :urls :accessor descriptor-urls :initform nil)
   (annotations :type hash-table :initarg :annotations :accessor descriptor-annotations
                :initform (make-hash-table :test 'equal))
   (data :type (or null (vector (unsigned-byte 8)))
         :initarg :data :accessor descriptor-data :initform nil)
   (artifact-type :type (or null string) :initarg :artifact-type
                  :accessor descriptor-artifact-type :initform nil)
   (platform :type (or null platform) :initarg :platform
             :accessor descriptor-platform :initform nil)))

(defun make-descriptor (&key media-type digest size urls annotations data artifact-type platform)
  (make-instance 'descriptor
                 :media-type media-type
                 :digest digest
                 :size size
                 :urls (or urls nil)
                 :annotations (or annotations (make-hash-table :test 'equal))
                 :data data
                 :artifact-type artifact-type
                 :platform platform))

(defun descriptor-annotation (descriptor key &optional default)
  "Get annotation value by KEY from DESCRIPTOR."
  (gethash key (descriptor-annotations descriptor) default))

(defun (setf descriptor-annotation) (value descriptor key)
  "Set annotation KEY to VALUE on DESCRIPTOR."
  (setf (gethash key (descriptor-annotations descriptor)) value))

(defmethod print-object ((d descriptor) stream)
  (print-unreadable-object (d stream :type t)
    (format stream "~a ~a (~d bytes)"
            (descriptor-media-type d)
            (when (descriptor-digest d) (format-digest (descriptor-digest d)))
            (descriptor-size d))))
