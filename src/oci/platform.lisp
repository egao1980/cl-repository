(defpackage :cl-oci/platform
  (:use :cl)
  (:export #:platform
           #:platform-os
           #:platform-architecture
           #:platform-os-version
           #:platform-os-features
           #:platform-variant
           #:make-platform
           #:platform-match-p))
(in-package :cl-oci/platform)

(defclass platform ()
  ((os :type (or null string) :initarg :os :accessor platform-os :initform nil)
   (architecture :type (or null string) :initarg :architecture :accessor platform-architecture :initform nil)
   (os-version :type (or null string) :initarg :os-version :accessor platform-os-version :initform nil)
   (os-features :type list :initarg :os-features :accessor platform-os-features :initform nil)
   (variant :type (or null string) :initarg :variant :accessor platform-variant :initform nil)))

(defun make-platform (&key os architecture os-version os-features variant)
  (make-instance 'platform
                 :os os
                 :architecture architecture
                 :os-version os-version
                 :os-features os-features
                 :variant variant))

(defmethod print-object ((p platform) stream)
  (print-unreadable-object (p stream :type t)
    (format stream "~@[~a~]~@[/~a~]~@[ ~a~]"
            (platform-os p) (platform-architecture p) (platform-variant p))))

(defun platform-match-p (query target)
  "Check if QUERY platform matches TARGET. NIL fields in QUERY match anything."
  (and (or (null (platform-os query))
           (string-equal (platform-os query) (platform-os target)))
       (or (null (platform-architecture query))
           (string-equal (platform-architecture query) (platform-architecture target)))
       (or (null (platform-variant query))
           (string-equal (platform-variant query) (platform-variant target)))
       (or (null (platform-os-version query))
           (string-equal (platform-os-version query) (platform-os-version target)))))
