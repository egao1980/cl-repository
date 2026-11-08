(uiop:define-package :cl-oci-client/tests/all
  (:use :cl)
  (:use-reexport
   :cl-oci-client/tests/registry-test
   :cl-oci-client/tests/pin-test))
