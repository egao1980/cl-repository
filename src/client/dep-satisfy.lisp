(defpackage :cl-repository-client/dep-satisfy
  (:use :cl)
  (:import-from :cl-repository-client/version-utils #:version<)
  (:import-from :cl-repository-client/protected-systems #:implementation-system-p)
  (:export #:asdf-dep-spec
           #:system-direct-dep-specs
           #:quicklisp-source-p
           #:system-satisfied-p
           #:asd-defsystem-form
           #:registry-copy-version
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
   Implementation systems (uiop, asdf, SBCL contribs) are satisfied without an OCI package."
  (when (implementation-system-p name)
    (return-from system-satisfied-p t))
  (let ((sys (asdf:find-system name nil)))
    (flet ((new-enough-p (have)
             (and have
                  (not (version< (princ-to-string have)
                                 (princ-to-string minimum))))))
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
