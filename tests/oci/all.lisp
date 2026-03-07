(uiop:define-package :cl-oci/tests/all
  (:use :cl)
  (:use-reexport
   :cl-oci/tests/digest-test
   :cl-oci/tests/descriptor-test
   :cl-oci/tests/manifest-test
   :cl-oci/tests/serialization-test))
