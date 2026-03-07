(defpackage :cl-oci/runtime
  (:use :cl)
  (:export #:*quiet*
           #:*dry-run*
           #:msg))
(in-package :cl-oci/runtime)

(defvar *quiet* nil "When true, suppress informational output.")
(defvar *dry-run* nil "When true, skip side-effecting operations (push, write, extract).")

(defun msg (fmt &rest args)
  "Print a formatted message unless *quiet* is true."
  (unless *quiet*
    (apply #'format t fmt args)))
