(defpackage :cl-oci/media-types
  (:use :cl)
  (:import-from :alexandria #:define-constant)
  (:export ;; OCI standard media types
           #:+oci-image-index-v1+
           #:+oci-image-manifest-v1+
           #:+oci-image-config-v1+
           #:+oci-image-layer-tar-gzip+
           #:+oci-image-layer-tar+
           #:+oci-image-layer-nondistributable-tar-gzip+
           #:+oci-empty-config+
           ;; Docker legacy media types
           #:+docker-manifest-v2+
           #:+docker-manifest-list-v2+
           ;; CL Repository media types
           #:+cl-system-config-v1+
           #:+cl-system-artifact-type+
           #:+cl-namespace-root-v1+
           #:+cl-system-name-anchor-v1+
           #:+cl-system-name-config-v1+))
(in-package :cl-oci/media-types)

;;; OCI Image Spec media types
(define-constant +oci-image-index-v1+ "application/vnd.oci.image.index.v1+json" :test #'equal)
(define-constant +oci-image-manifest-v1+ "application/vnd.oci.image.manifest.v1+json" :test #'equal)
(define-constant +oci-image-config-v1+ "application/vnd.oci.image.config.v1+json" :test #'equal)
(define-constant +oci-image-layer-tar-gzip+ "application/vnd.oci.image.layer.v1.tar+gzip" :test #'equal)
(define-constant +oci-image-layer-tar+ "application/vnd.oci.image.layer.v1.tar" :test #'equal)
(define-constant +oci-image-layer-nondistributable-tar-gzip+
  "application/vnd.oci.image.layer.nondistributable.v1.tar+gzip" :test #'equal)
(define-constant +oci-empty-config+ "application/vnd.oci.empty.v1+json" :test #'equal)

;;; Docker legacy media types
(define-constant +docker-manifest-v2+ "application/vnd.docker.distribution.manifest.v2+json" :test #'equal)
(define-constant +docker-manifest-list-v2+ "application/vnd.docker.distribution.manifest.list.v2+json"
  :test #'equal)

;;; CL Repository specific media types
(define-constant +cl-system-config-v1+ "application/vnd.common-lisp.system.config.v1+json" :test #'equal)
(define-constant +cl-system-artifact-type+ "application/vnd.common-lisp.system.v1" :test #'equal)
(define-constant +cl-namespace-root-v1+ "application/vnd.common-lisp.namespace-root.v1" :test #'equal)
(define-constant +cl-system-name-anchor-v1+ "application/vnd.common-lisp.system-name.v1" :test #'equal)
(define-constant +cl-system-name-config-v1+ "application/vnd.common-lisp.system-name.config.v1+json" :test #'equal)
