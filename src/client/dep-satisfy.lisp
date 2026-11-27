(defpackage :cl-repository-client/dep-satisfy
  (:use :cl)
  (:import-from :cl-repository-client/version-utils #:version<)
  (:import-from :cl-repository-client/protected-systems #:implementation-system-p)
  (:import-from :cl-oci-client/pin #:pinned-system-p)
  (:export #:asdf-dep-spec
           #:system-direct-dep-specs
           #:quicklisp-source-p
           #:system-satisfied-p
           #:asd-defsystem-form
           #:registry-copy-version
           #:shadowed-registry-asd
           #:asd-form-version
           #:resolved-copy
           #:note-minimum))
(in-package :cl-repository-client/dep-satisfy)

(defun asdf-dep-spec (dep)
  "Return (values name minimum-version). MINIMUM-VERSION is a string or NIL.
   Feature deps that are off, and :require deps, return NIL."
  (cond
    ((stringp dep) (values (string-downcase dep) nil))
    ((and (symbolp dep) (not (keywordp dep)))
     (values (string-downcase (symbol-name dep)) nil))
    ((and (consp dep) (eq (first dep) :version) (>= (length dep) 3))
     (values (asdf-dep-spec (second dep)) (princ-to-string (third dep))))
    ((and (consp dep) (eq (first dep) :feature) (>= (length dep) 3))
     (if (uiop:featurep (second dep))
         (asdf-dep-spec (third dep))
         (values nil nil)))
    ((and (consp dep) (eq (first dep) :require))
     (values nil nil))
    (t (values nil nil))))

(defun system-direct-dep-specs (system)
  "Alist of (name . minimum-version) for SYSTEM's direct :depends-on entries."
  (let ((sys (if (typep system 'asdf:system)
                 system
                 (asdf:find-system system nil))))
    (when sys
      (loop for dep in (asdf:system-depends-on sys)
            for spec = (multiple-value-list (asdf-dep-spec dep))
            for name = (first spec)
            for minimum = (second spec)
            when name
              collect (cons name minimum)))))

(defun quicklisp-source-p (system)
  "True when SYSTEM's source directory is a Quicklisp dist tree.
   A findable Quicklisp copy is not an OCI install."
  (let ((dir (ignore-errors
              (asdf:system-source-directory
               (if (typep system 'asdf:system) system (asdf:find-system system nil))))))
    (and dir (search "quicklisp" (namestring dir) :test #'char-equal))))

(defun asd-defsystem-form (file name)
  "The DEFSYSTEM form for system NAME in FILE, read without evaluating
   anything (*READ-EVAL* off, a scratch package), or NIL when none can be read."
  (let ((*read-eval* nil)
        (*package* (make-package (gensym "DEFSYSTEM-ASD-") :use '(:cl))))
    (unwind-protect
         (ignore-errors
          (with-open-file (in file :external-format :utf-8)
            (loop for form = (read in nil in)
                  until (eq form in)
                  when (and (consp form) (symbolp (first form))
                            (string= "DEFSYSTEM" (symbol-name (first form)))
                            (or (stringp (second form)) (symbolp (second form)))
                            (string-equal name (string (second form))))
                    return form)))
      (delete-package *package*))))

(defun shadowed-registry-asd (name)
  "The .asd that a fresh image started with the current source registry reads
   for NAME's primary system, when this image answers NAME from another copy:
   the client runs that primary system and WITH-LOADED-SYSTEMS-PINNED keeps it
   on the .asd it was loaded from (the client's encoding-protocol 0.3.0, while
   the project syncs 0.4.0 into the install tree). NIL when the primary is
   not pinned, or the registry gives the same file or none.
   The file is data for the fresh image only: it is read with
   ASD-DEFSYSTEM-FORM, never loaded here. FIND-SYSTEM of a secondary system
   (\"encoding-protocol/cjk\") would load the pinned primary's .asd again,
   which has no such system, and the reload leaves the running primary no
   longer COMPONENT-LOADED-P (cl-repository#180)."
  (let* ((n (string-downcase (string name)))
         (primary (asdf:primary-system-name n)))
    (when (pinned-system-p primary)
      (let* ((sys (asdf:registered-system primary))
             (own (and sys (ignore-errors (asdf:system-source-file sys))))
             (file (ignore-errors (asdf/source-registry:sysdef-source-registry-search primary))))
        (when (and file
                   (or (null own)
                       (not (equal (uiop:truename* file) (uiop:truename* own)))))
          file)))))

(defun asd-form-version (file name)
  "The literal :VERSION of system NAME in FILE; for a secondary system without
   one, its primary system's. NIL when none is a literal string."
  (flet ((literal (system)
           (let* ((form (asd-defsystem-form file system))
                  (version (and form (ignore-errors (getf (cddr form) :version)))))
             (and (stringp version) version))))
    (let ((n (string-downcase (string name))))
      (or (literal n)
          (let ((primary (asdf:primary-system-name n)))
            (and (string/= primary n) (literal primary)))))))

(defun resolved-copy (name)
  "(values file version) of the copy of NAME's primary system this image
   resolves: the pinned one while the client runs it, else the source
   registry's. For messages."
  (let* ((primary (asdf:primary-system-name (string-downcase (string name))))
         (sys (and (pinned-system-p primary) (asdf:registered-system primary)))
         (file (or (and sys (ignore-errors (asdf:system-source-file sys)))
                   (ignore-errors (asdf/source-registry:sysdef-source-registry-search primary)))))
    (values file (and file (asd-form-version file primary)))))

(defun registry-copy-version (name sys)
  "The version of NAME a fresh image started with the current source registry
   loads, when that is another .asd than the one SYS was read from: this image
   runs its own copy (the client's tree under CL_REPOSITORY_DEST), but the
   registry puts the installed systems first, so `cl-repo run` / `cl-repo
   test` children get the installed copy (#119). NIL when the registry has
   the same file, has none, or the copy's :version is not a literal string."
  (let* ((n (string-downcase (string name)))
         (file (ignore-errors (asdf/source-registry:sysdef-source-registry-search n)))
         (own (ignore-errors (asdf:system-source-file sys))))
    (when (and file own
               (not (equal (uiop:truename* file) (uiop:truename* own))))
      (let* ((form (asd-defsystem-form file n))
             (version (and form (ignore-errors (getf (cddr form) :version)))))
        (and (stringp version) version)))))

(defun system-satisfied-p (name &optional minimum)
  "True when NAME is findable from OCI or the project, new enough, and not a Quicklisp tree.
   With MINIMUM, the copy the source registry gives a fresh image must be new
   enough too (REGISTRY-COPY-VERSION): the client's own newer copy does not count.
   When the client runs NAME's primary system and the registry gives a fresh
   image another copy (SHADOWED-REGISTRY-ASD), that copy alone decides,
   read without loading it: a secondary system it defines and the client's
   copy lacks is there, and its :version is the one checked (#180).
   Implementation systems (uiop, asdf, SBCL contribs) are satisfied without an OCI package."
  (when (implementation-system-p name)
    (return-from system-satisfied-p t))
  (flet ((new-enough-p (have)
           (and have
                (not (version< (princ-to-string have)
                               (princ-to-string minimum))))))
    (let ((shadowing (shadowed-registry-asd name)))
      (when (and shadowing (asd-defsystem-form shadowing (string-downcase (string name))))
        (return-from system-satisfied-p
          (and (not (search "quicklisp" (namestring shadowing) :test #'char-equal))
               (or (null minimum)
                   (let ((have (asd-form-version shadowing name)))
                     (or (null have) (new-enough-p have))))
               t))))
    (let ((sys (asdf:find-system name nil)))
      (and sys
           (not (quicklisp-source-p sys))
           (or (null minimum)
               (and (new-enough-p (ignore-errors (asdf:component-version sys)))
                    (let ((registry-copy (registry-copy-version name sys)))
                      (or (null registry-copy) (new-enough-p registry-copy)))))))))

(defun note-minimum (table name minimum)
  "Record the highest MINIMUM seen for NAME."
  (when (and name minimum)
    (let ((prev (gethash name table)))
      (when (or (null prev) (version< prev minimum))
        (setf (gethash name table) minimum)))))
