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
           #:+cl-provides+
           #:+cl-alias-for+
           #:+cl-depends-on-versioned+))
(in-package :cl-oci/annotations)

(defmacro define-annotations (&body pairs)
  "Define each (NAME STRING) pair as a string constant tested with EQUAL."
  `(progn
     ,@(loop for (name value) in pairs
             collect `(define-constant ,name ,value :test #'equal))))

;;; Standard OCI annotation keys (org.opencontainers.image.*)
(define-annotations
  (+ann-created+ "org.opencontainers.image.created")
  (+ann-authors+ "org.opencontainers.image.authors")
  (+ann-url+ "org.opencontainers.image.url")
  (+ann-documentation+ "org.opencontainers.image.documentation")
  (+ann-source+ "org.opencontainers.image.source")
  (+ann-version+ "org.opencontainers.image.version")
  (+ann-revision+ "org.opencontainers.image.revision")
  (+ann-vendor+ "org.opencontainers.image.vendor")
  (+ann-licenses+ "org.opencontainers.image.licenses")
  (+ann-ref-name+ "org.opencontainers.image.ref.name")
  (+ann-title+ "org.opencontainers.image.title")
  (+ann-description+ "org.opencontainers.image.description")
  (+ann-base-image-digest+ "org.opencontainers.image.base.digest")
  (+ann-base-image-name+ "org.opencontainers.image.base.name"))

;;; CL Repository annotation keys (dev.common-lisp.*)
(define-annotations
  (+cl-implementation+ "dev.common-lisp.implementation")
  (+cl-implementation-version+ "dev.common-lisp.implementation.version")
  (+cl-features+ "dev.common-lisp.features")
  (+cl-layer-roles+ "dev.common-lisp.layer.roles")
  (+cl-has-native-deps+ "dev.common-lisp.has-native-deps")
  (+cl-cffi-libraries+ "dev.common-lisp.cffi-libraries")
  (+cl-system-name+ "dev.common-lisp.system.name")
  (+cl-depends-on+ "dev.common-lisp.system.depends-on")
  (+cl-provides+ "dev.common-lisp.system.provides")
  (+cl-alias-for+ "dev.common-lisp.alias-for")
  (+cl-depends-on-versioned+ "dev.common-lisp.system.depends-on.versioned"))
