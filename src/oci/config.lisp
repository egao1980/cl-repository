(defpackage :cl-oci/config
  (:use :cl)
  (:import-from :alexandria #:define-constant)
  (:export #:cl-system-config
           #:config-system-name
           #:config-version
           #:config-depends-on
           #:config-provides
           #:config-layer-roles
           #:config-cffi-libraries
           #:config-grovel-systems
           #:config-build-requires
           #:make-cl-system-config
           ;; Layer role constants
           #:+role-source+
           #:+role-native-library+
           #:+role-static-library+
           #:+role-cffi-grovel-output+
           #:+role-cffi-wrapper+
           #:+role-headers+
           #:+role-documentation+
           #:+role-build-script+))
(in-package :cl-oci/config)

;;; Layer role constants
(define-constant +role-source+ "source" :test #'equal)
(define-constant +role-native-library+ "native-library" :test #'equal)
(define-constant +role-static-library+ "static-library" :test #'equal)
(define-constant +role-cffi-grovel-output+ "cffi-grovel-output" :test #'equal)
(define-constant +role-cffi-wrapper+ "cffi-wrapper" :test #'equal)
(define-constant +role-headers+ "headers" :test #'equal)
(define-constant +role-documentation+ "documentation" :test #'equal)
(define-constant +role-build-script+ "build-script" :test #'equal)

(defclass cl-system-config ()
  ((system-name :type string :initarg :system-name :accessor config-system-name)
   (version :type (or null string) :initarg :version :accessor config-version :initform nil)
   (depends-on :type list :initarg :depends-on :accessor config-depends-on :initform nil)
   (provides :type list :initarg :provides :accessor config-provides :initform nil)
   (layer-roles :type hash-table :initarg :layer-roles :accessor config-layer-roles
                :initform (make-hash-table :test 'equal))
   (cffi-libraries :type list :initarg :cffi-libraries :accessor config-cffi-libraries :initform nil)
   (grovel-systems :type list :initarg :grovel-systems :accessor config-grovel-systems :initform nil)
   (build-requires :type list :initarg :build-requires :accessor config-build-requires :initform nil)))

(defun make-cl-system-config (&key system-name version depends-on provides
                                layer-roles cffi-libraries grovel-systems build-requires)
  (make-instance 'cl-system-config
                 :system-name system-name
                 :version version
                 :depends-on (or depends-on nil)
                 :provides (or provides nil)
                 :layer-roles (or layer-roles (make-hash-table :test 'equal))
                 :cffi-libraries (or cffi-libraries nil)
                 :grovel-systems (or grovel-systems nil)
                 :build-requires (or build-requires nil)))
