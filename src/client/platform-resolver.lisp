(defpackage :cl-repository-client/platform-resolver
  (:use :cl)
  (:import-from :cl-oci/descriptor #:descriptor-platform #:descriptor-annotations)
  (:import-from :cl-oci/platform #:platform-os #:platform-architecture)
  (:import-from :cl-oci/annotations #:+cl-implementation+ #:+cl-overlay-name+)
  (:import-from :cl-oci/image-index #:image-index-manifests)
  (:export #:detect-local-platform
           #:detect-local-os
           #:detect-local-arch
           #:detect-local-implementation
           #:resolve-manifests
           #:universal-manifest-p
           #:overlay-key
           #:choose-overlay-plists))
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

(defun overlay-key (&key os arch lisp)
  "Join the parts that are present. Empty parts are wildcards and are omitted."
  (format nil "~{~a~^-~}"
          (remove-if (lambda (part) (not (present-text part)))
                     (list os arch lisp))))

(defun universal-manifest-p (descriptor)
  "Universal source manifest: no platform, no lisp annotation, no overlay name.
   A lisp-only overlay has no platform and is not universal."
  (and (null (descriptor-platform descriptor))
       (not (annotation-text descriptor +cl-implementation+))
       (not (annotation-text descriptor +cl-overlay-name+))))

(defun descriptor-os (descriptor)
  (let ((plat (descriptor-platform descriptor)))
    (when plat
      (present-text (platform-os plat)))))

(defun descriptor-arch (descriptor)
  (let ((plat (descriptor-platform descriptor)))
    (when plat
      (present-text (platform-architecture plat)))))

(defun descriptor-lisp (descriptor)
  (annotation-text descriptor +cl-implementation+))

(defun annotated-overlay-name (descriptor)
  (annotation-text descriptor +cl-overlay-name+))

(defun text-matches-p (actual expected)
  "NIL ACTUAL matches any machine. A set ACTUAL must string-equal EXPECTED."
  (or (null actual)
      (and (stringp expected) (string-equal actual expected))))

(defun automatic-name-p (name os arch lisp)
  "A missing name, or a name equal to the key, is installed by sync."
  (or (null (present-text name))
      (string-equal name (overlay-key :os os :arch arch :lisp lisp))))

(defun host-match-p (os arch lisp host-os host-arch host-lisp)
  (and (text-matches-p os host-os)
       (text-matches-p arch host-arch)
       (text-matches-p lisp host-lisp)))

(defun overlay-specificity (descriptor)
  "How many of os, architecture, and implementation are set. Range 0..3."
  (+ (if (descriptor-os descriptor) 1 0)
     (if (descriptor-arch descriptor) 1 0)
     (if (descriptor-lisp descriptor) 1 0)))

(defun overlay-order-name (descriptor)
  "Tie-break string. Unnamed overlays share \"\" so manifest order decides."
  (or (annotated-overlay-name descriptor) ""))

(defun ranked-before-p (left right)
  "LEFT and RIGHT are (position . descriptor). Generic first, then name, then order."
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

(defun host-parts (os os-p arch arch-p implementation impl-p)
  (multiple-value-bind (detected-os detected-arch detected-impl) (detect-local-platform)
    (values (if os-p os detected-os)
            (if arch-p arch detected-arch)
            (if impl-p implementation detected-impl))))

(defun resolve-manifests (index &key (os nil os-p) (arch nil arch-p)
                                     (implementation nil impl-p) overlay)
  "Resolve manifest descriptors for this machine.
   Returns (values universal-desc overlay-descs).
   Automatic overlays stack generic-first. OVERLAY names an opt-in overlay
   which is appended on top. OS, ARCH, and IMPLEMENTATION default to this
   machine when the keyword is omitted."
  (multiple-value-bind (os arch implementation)
      (host-parts os os-p arch arch-p implementation impl-p)
    (let ((universal nil)
          (automatic nil)
          (named nil))
      (loop for desc in (image-index-manifests index)
            for position from 0
            do (let ((dos (descriptor-os desc))
                     (darch (descriptor-arch desc))
                     (dlisp (descriptor-lisp desc))
                     (dname (annotated-overlay-name desc)))
                 (cond
                   ((universal-manifest-p desc)
                    (setf universal desc))
                   ((and (automatic-name-p dname dos darch dlisp)
                         (host-match-p dos darch dlisp os arch implementation))
                    (push (cons position desc) automatic))
                   ((and (present-text overlay)
                         (present-text dname)
                         (string-equal dname overlay)
                         (not (automatic-name-p dname dos darch dlisp))
                         (host-match-p dos darch dlisp os arch implementation))
                    (push (cons position desc) named)))))
      (values universal
              (append (mapcar #'cdr (sort automatic #'ranked-before-p))
                      (mapcar #'cdr (sort named #'ranked-before-p)))))))

(defun plist-specificity (plist)
  (let ((plat (getf plist :platform)))
    (+ (if (present-text (getf plat :os)) 1 0)
       (if (present-text (getf plat :arch)) 1 0)
       (if (present-text (getf plat :lisp)) 1 0))))

(defun choose-overlay-plists (overlays &key name (os nil os-p) (arch nil arch-p)
                                            (implementation nil impl-p))
  "Same selection as RESOLVE-MANIFESTS, over :cl-repo overlay plists.
   NAME NIL returns the automatic stack. A name returns that overlay."
  (multiple-value-bind (os arch implementation)
      (host-parts os os-p arch arch-p implementation impl-p)
    (let ((automatic nil)
          (named nil))
      (loop for plist in overlays
            for position from 0
            do (let* ((plat (getf plist :platform))
                      (dos (present-text (getf plat :os)))
                      (darch (present-text (getf plat :arch)))
                      (dlisp (present-text (getf plat :lisp)))
                      (dname (present-text (getf plist :name))))
                 (when (host-match-p dos darch dlisp os arch implementation)
                   (cond
                     ((automatic-name-p dname dos darch dlisp)
                      (push (list position plist) automatic))
                     ((and (present-text name) dname (string-equal dname name))
                      (push (list position plist) named))))))
      (flet ((order (pairs)
               (mapcar #'second
                       (sort pairs
                             (lambda (a b)
                               (let ((sa (plist-specificity (second a)))
                                     (sb (plist-specificity (second b))))
                                 (cond ((< sa sb) t)
                                       ((> sa sb) nil)
                                       (t (< (first a) (first b))))))))))
        (if (present-text name)
            (or (order named)
                (remove-if-not
                 (lambda (plist)
                   (let ((entry-name (getf plist :name)))
                     (and entry-name (string-equal entry-name name))))
                 (order automatic)))
            (order automatic))))))
