(defpackage :cl-repository-ql-exporter/asd-introspector
  (:use :cl)
  (:export #:asd-metadata
           #:asd-metadata-name
           #:asd-metadata-version
           #:asd-metadata-description
           #:asd-metadata-author
           #:asd-metadata-license
           #:asd-metadata-depends-on
           #:asd-metadata-has-cffi-p
           #:extract-asd-metadata))
(in-package :cl-repository-ql-exporter/asd-introspector)

(defclass asd-metadata ()
  ((name :type (or null string) :initarg :name :accessor asd-metadata-name :initform nil)
   (version :type (or null string) :initarg :version :accessor asd-metadata-version :initform nil)
   (description :type (or null string) :initarg :description :accessor asd-metadata-description
                :initform nil)
   (author :type (or null string) :initarg :author :accessor asd-metadata-author :initform nil)
   (license :type (or null string) :initarg :license :accessor asd-metadata-license :initform nil)
   (depends-on :type list :initarg :depends-on :accessor asd-metadata-depends-on :initform nil)
   (has-cffi-p :type boolean :initarg :has-cffi-p :accessor asd-metadata-has-cffi-p :initform nil)))

(defun extract-asd-metadata (asd-path)
  "Extract metadata from a .asd file without loading it. Reads the defsystem form
   and extracts key properties. Returns an ASD-METADATA instance."
  (handler-case
      (let ((forms (read-asd-forms asd-path)))
        (dolist (form forms)
          (when (and (listp form)
                     (symbolp (first form))
                     (string-equal "DEFSYSTEM" (symbol-name (first form))))
            (return-from extract-asd-metadata (parse-defsystem-form form)))))
    (error (e)
      (declare (ignore e))
      (make-instance 'asd-metadata))))

(defun read-asd-forms (path)
  "Read all top-level forms from a .asd file safely."
  (let ((*read-eval* nil)
        (*package* (find-package :cl-user))
        (forms nil))
    (handler-case
        (with-open-file (s path :direction :input :if-does-not-exist nil)
          (when s
            (loop for form = (read s nil :eof)
                  until (eq form :eof)
                  do (push form forms))))
      (error () nil))
    (nreverse forms)))

(defun stringify (x)
  "Coerce a value to string, handling symbols and other types."
  (etypecase x
    (string x)
    (symbol (string-downcase (symbol-name x)))
    (number (write-to-string x))
    (null nil)))

(defun parse-defsystem-form (form)
  "Extract metadata from a (defsystem ...) form."
  (let ((name (stringify (second form)))
        (plist (cddr form))
        (deps nil)
        (has-cffi nil))
    ;; Flatten the plist for property extraction
    (let ((version (stringify (getf plist :version)))
          (description (stringify (getf plist :description)))
          (author (stringify (getf plist :author)))
          (license (or (stringify (getf plist :license))
                       (stringify (getf plist :licence)))))
      ;; Extract depends-on
      (let ((dep-list (getf plist :depends-on)))
        (when dep-list
          (setf deps (mapcar (lambda (d)
                               (etypecase d
                                 (string d)
                                 (symbol (string-downcase (symbol-name d)))
                                 (cons (string-downcase (symbol-name (second d))))))
                             dep-list))
          ;; Check for CFFI dependency
          (setf has-cffi (or (member "cffi" deps :test #'string-equal)
                             (member "cffi-grovel" deps :test #'string-equal)
                             (member "cffi-toolchain" deps :test #'string-equal)))))
      ;; Also scan components for grovel-file
      (let ((components (getf plist :components)))
        (when (and components (scan-for-grovel-components components))
          (setf has-cffi t)))
      (make-instance 'asd-metadata
                     :name name
                     :version version
                     :description description
                     :author author
                     :license license
                     :depends-on deps
                     :has-cffi-p has-cffi))))

(defun scan-for-grovel-components (components)
  "Recursively scan ASDF component specs for cffi:grovel-file or cffi:wrapper-file."
  (when (listp components)
    (dolist (c components)
      (when (listp c)
        (let ((type (first c)))
          (when (and (symbolp type)
                     (member (string-downcase (symbol-name type))
                             '("grovel-file" "wrapper-file") :test #'string=))
            (return-from scan-for-grovel-components t))
          ;; Recurse into :module components
          (let ((sub-components (getf (cddr c) :components)))
            (when (scan-for-grovel-components sub-components)
              (return-from scan-for-grovel-components t))))))
    nil))
