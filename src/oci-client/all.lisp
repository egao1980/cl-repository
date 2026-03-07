(uiop:define-package :cl-oci-client/all
  (:nicknames :cl-oci-client)
  (:use-reexport
   :cl-oci-client/conditions
   :cl-oci-client/auth
   :cl-oci-client/registry
   :cl-oci-client/pull
   :cl-oci-client/push
   :cl-oci-client/content-discovery))
