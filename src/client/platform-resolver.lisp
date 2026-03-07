(defpackage :cl-repository-client/platform-resolver
  (:use :cl)
  (:import-from :cl-oci/descriptor #:descriptor #:descriptor-platform #:descriptor-annotations
                #:descriptor-media-type)
  (:import-from :cl-oci/platform #:platform #:platform-os #:platform-architecture)
  (:import-from :cl-oci/annotations #:+cl-implementation+)
  (:import-from :cl-oci/image-index #:image-index #:image-index-manifests)
  (:export #:detect-local-platform
           #:resolve-manifests
           #:universal-manifest-p))
(in-package :cl-repository-client/platform-resolver)

(defun detect-local-os ()
  "Detect local OS using *features*. Returns OCI platform os string."
  (cond
    #+linux ((member :linux *features*) "linux")
    #+darwin ((member :darwin *features*) "darwin")
    #+windows ((member :windows *features*) "windows")
    #+freebsd ((member :freebsd *features*) "freebsd")
    #+openbsd ((member :openbsd *features*) "openbsd")
    (t (cond ((member :linux *features*) "linux")
             ((member :darwin *features*) "darwin")
             ((member :windows *features*) "windows")
             (t nil)))))

(defun detect-local-arch ()
  "Detect local CPU architecture using *features*. Returns OCI platform architecture string."
  (cond
    ((member :x86-64 *features*) "amd64")
    ((member :x86 *features*) "386")
    ((member :arm64 *features*) "arm64")
    ((member :arm *features*) "arm")
    ((member :ppc64 *features*) "ppc64")
    ((member :ppc *features*) "ppc")
    (t nil)))

(defun detect-local-implementation ()
  "Detect current CL implementation name."
  (string-downcase (lisp-implementation-type)))

(defun detect-local-platform ()
  "Returns (values os architecture implementation)."
  (values (detect-local-os)
          (detect-local-arch)
          (detect-local-implementation)))

(defun universal-manifest-p (descriptor)
  "A manifest descriptor is universal if it has no platform field."
  (null (descriptor-platform descriptor)))

(defun platform-matches-p (descriptor os arch)
  "Check if a manifest descriptor's platform matches the given os/arch."
  (let ((plat (descriptor-platform descriptor)))
    (and plat
         (or (null os) (string-equal (platform-os plat) os))
         (or (null arch) (string-equal (platform-architecture plat) arch)))))

(defun implementation-matches-p (descriptor impl)
  "Check if a manifest descriptor's CL implementation annotation matches."
  (if impl
      (let ((ann-impl (gethash +cl-implementation+ (descriptor-annotations descriptor))))
        (or (null ann-impl) (string-equal ann-impl impl)))
      t))

(defun resolve-manifests (index)
  "Resolve which manifest descriptors to pull from an image index.
   Returns (values universal-desc overlay-descs)."
  (multiple-value-bind (os arch impl) (detect-local-platform)
    (let ((universal nil)
          (overlays nil))
      (dolist (desc (image-index-manifests index))
        (cond
          ((universal-manifest-p desc)
           (setf universal desc))
          ((and (platform-matches-p desc os arch)
                (implementation-matches-p desc impl))
           (push desc overlays))))
      (values universal (nreverse overlays)))))
