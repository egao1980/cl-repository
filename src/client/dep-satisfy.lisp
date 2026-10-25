(defpackage :cl-repository-client/dep-satisfy
  (:use :cl)
  (:import-from :cl-repository-client/version-utils #:version<)
  (:export #:asdf-dep-spec
           #:system-direct-dep-specs
           #:quicklisp-source-p
           #:system-satisfied-p
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

(defun system-satisfied-p (name &optional minimum)
  "True when NAME is findable from OCI or the project, new enough, and not a Quicklisp tree."
  (let ((sys (asdf:find-system name nil)))
    (and sys
         (not (quicklisp-source-p sys))
         (or (null minimum)
             (let ((have (ignore-errors (asdf:component-version sys))))
               (and have
                    (not (version< (princ-to-string have)
                                   (princ-to-string minimum)))))))))

(defun note-minimum (table name minimum)
  "Record the highest MINIMUM seen for NAME."
  (when (and name minimum)
    (let ((prev (gethash name table)))
      (when (or (null prev) (version< prev minimum))
        (setf (gethash name table) minimum)))))
