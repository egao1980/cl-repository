(defpackage :cl-repository-client/platform-resolver
  (:use :cl)
  (:import-from :cl-oci/descriptor #:descriptor-platform #:descriptor-annotations)
  (:import-from :cl-oci/platform #:platform-os #:platform-architecture)
  (:import-from :cl-oci/annotations #:+cl-implementation+)
  (:import-from :cl-oci/image-index #:image-index-manifests)
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

(defun present-text (value)
  "Return VALUE when it is a non-empty string, otherwise NIL."
  (when (and (stringp value) (plusp (length value)))
    value))

(defun annotation-text (descriptor key)
  "Non-empty annotation KEY on DESCRIPTOR, or NIL."
  (let ((anns (descriptor-annotations descriptor)))
    (when anns
      (present-text (gethash key anns)))))

(defun universal-manifest-p (descriptor)
  "A manifest is universal when it has no platform and no implementation annotation."
  (and (null (descriptor-platform descriptor))
       (not (annotation-text descriptor +cl-implementation+))))

(defun descriptor-os (descriptor)
  (let ((plat (descriptor-platform descriptor)))
    (when plat
      (present-text (platform-os plat)))))

(defun descriptor-arch (descriptor)
  (let ((plat (descriptor-platform descriptor)))
    (when plat
      (present-text (platform-architecture plat)))))

(defun overlay-name (descriptor)
  "Opt-in overlay name, or NIL. A set name is not an automatic match."
  (annotation-text descriptor "dev.common-lisp.overlay.name"))

(defun text-matches-p (actual expected)
  "NIL ACTUAL matches any machine. A set ACTUAL must string-equal EXPECTED."
  (or (null actual)
      (and (stringp expected) (string-equal actual expected))))

(defun overlay-specificity (descriptor)
  "How many of os, architecture, and implementation are set. Range 0..3."
  (+ (if (descriptor-os descriptor) 1 0)
     (if (descriptor-arch descriptor) 1 0)
     (if (annotation-text descriptor +cl-implementation+) 1 0)))

(defun automatic-overlay-p (descriptor os arch implementation)
  "True when DESCRIPTOR is an unnamed overlay whose set parts match this machine."
  (and (not (overlay-name descriptor))
       (text-matches-p (descriptor-os descriptor) os)
       (text-matches-p (descriptor-arch descriptor) arch)
       (text-matches-p (annotation-text descriptor +cl-implementation+) implementation)))

(defun overlay-order-name (descriptor)
  "Tie-break string: the overlay name annotation, or \"\" when it is absent."
  (or (overlay-name descriptor) ""))

(defun ranked-before-p (left right)
  "LEFT is (position . descriptor). Generic first, then name, then manifest order."
  (let* ((left-desc (cdr left))
         (right-desc (cdr right))
         (left-spec (overlay-specificity left-desc))
         (right-spec (overlay-specificity right-desc)))
    (cond ((< left-spec right-spec) t)
          ((> left-spec right-spec) nil)
          (t (let ((left-name (overlay-order-name left-desc))
                   (right-name (overlay-order-name right-desc)))
               (cond ((string< left-name right-name) t)
                     ((string< right-name left-name) nil)
                     (t (< (car left) (car right)))))))))

(defun resolve-manifests (index &key (os nil os-p) (arch nil arch-p) (implementation nil impl-p))
  "Resolve manifest descriptors for this machine.
   Returns (values universal-desc overlay-descs).
   Every matching non-named overlay is returned, least specific first.
   OS, ARCH, and IMPLEMENTATION default to detect-local-platform when omitted."
  (multiple-value-bind (detected-os detected-arch detected-impl)
      (if (and os-p arch-p impl-p)
          (values nil nil nil)
          (detect-local-platform))
    (unless os-p (setf os detected-os))
    (unless arch-p (setf arch detected-arch))
    (unless impl-p (setf implementation detected-impl))
    (let ((universal nil)
          (matches nil))
      (loop for desc in (image-index-manifests index)
            for position from 0
            do (cond
                 ((universal-manifest-p desc)
                  (setf universal desc))
                 ((automatic-overlay-p desc os arch implementation)
                  (push (cons position desc) matches))))
      (values universal
              (mapcar #'cdr (sort matches #'ranked-before-p))))))
