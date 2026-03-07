(defpackage :cl-repository-ql-exporter/incremental
  (:use :cl)
  (:import-from :cl-oci-client/registry #:registry #:make-registry)
  (:import-from :cl-oci-client/pull #:head-manifest)
  (:export #:manifest-exists-in-registry-p))
(in-package :cl-repository-ql-exporter/incremental)

(defun manifest-exists-in-registry-p (registry repository tag)
  "Check if a manifest already exists at REGISTRY/REPOSITORY:TAG.
   Returns T if it exists, NIL otherwise."
  (handler-case
      (multiple-value-bind (status headers) (head-manifest registry repository tag)
        (declare (ignore headers))
        (and status (= status 200)))
    (error () nil)))
