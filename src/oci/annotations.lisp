(defpackage :cl-oci/annotations
  (:use :cl)
  (:import-from :alexandria #:define-constant)
  (:export ;; Standard OCI annotations
           #:+ann-created+
           #:+ann-authors+
           #:+ann-url+
           #:+ann-documentation+
           #:+ann-source+
           #:+ann-version+
           #:+ann-revision+
           #:+ann-vendor+
           #:+ann-licenses+
           #:+ann-ref-name+
           #:+ann-title+
           #:+ann-description+
           #:+ann-base-image-digest+
           #:+ann-base-image-name+
           ;; CL-specific annotations
           #:+cl-implementation+
           #:+cl-implementation-version+
           #:+cl-features+
           #:+cl-layer-roles+
           #:+cl-has-native-deps+
           #:+cl-cffi-libraries+
           #:+cl-system-name+
           #:+cl-depends-on+
           #:+cl-provides+))
(in-package :cl-oci/annotations)

;;; Standard OCI annotation keys (org.opencontainers.image.*)
(define-constant +ann-created+ "org.opencontainers.image.created" :test #'equal)
(define-constant +ann-authors+ "org.opencontainers.image.authors" :test #'equal)
(define-constant +ann-url+ "org.opencontainers.image.url" :test #'equal)
(define-constant +ann-documentation+ "org.opencontainers.image.documentation" :test #'equal)
(define-constant +ann-source+ "org.opencontainers.image.source" :test #'equal)
(define-constant +ann-version+ "org.opencontainers.image.version" :test #'equal)
(define-constant +ann-revision+ "org.opencontainers.image.revision" :test #'equal)
(define-constant +ann-vendor+ "org.opencontainers.image.vendor" :test #'equal)
(define-constant +ann-licenses+ "org.opencontainers.image.licenses" :test #'equal)
(define-constant +ann-ref-name+ "org.opencontainers.image.ref.name" :test #'equal)
(define-constant +ann-title+ "org.opencontainers.image.title" :test #'equal)
(define-constant +ann-description+ "org.opencontainers.image.description" :test #'equal)
(define-constant +ann-base-image-digest+ "org.opencontainers.image.base.digest" :test #'equal)
(define-constant +ann-base-image-name+ "org.opencontainers.image.base.name" :test #'equal)

;;; CL Repository annotation keys (dev.common-lisp.*)
(define-constant +cl-implementation+ "dev.common-lisp.implementation" :test #'equal)
(define-constant +cl-implementation-version+ "dev.common-lisp.implementation.version" :test #'equal)
(define-constant +cl-features+ "dev.common-lisp.features" :test #'equal)
(define-constant +cl-layer-roles+ "dev.common-lisp.layer.roles" :test #'equal)
(define-constant +cl-has-native-deps+ "dev.common-lisp.has-native-deps" :test #'equal)
(define-constant +cl-cffi-libraries+ "dev.common-lisp.cffi-libraries" :test #'equal)
(define-constant +cl-system-name+ "dev.common-lisp.system.name" :test #'equal)
(define-constant +cl-depends-on+ "dev.common-lisp.system.depends-on" :test #'equal)
(define-constant +cl-provides+ "dev.common-lisp.system.provides" :test #'equal)
