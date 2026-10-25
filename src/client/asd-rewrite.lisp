(defpackage :cl-repository-client/asd-rewrite
  (:use :cl)
  (:import-from :cl-repository-client/platform-resolver
                #:detect-local-platform #:overlay-key)
  (:export #:cmd-add-overlay
           #:read-system-overlays
           #:overlay-entry-key))
(in-package :cl-repository-client/asd-rewrite)

(defun read-lisp-forms (path)
  (with-open-file (in path :direction :input)
    (let ((*read-eval* nil))
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            collect form))))

(defun write-lisp-forms (path forms)
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (let ((*print-case* :downcase)
          (*print-pretty* t)
          (*print-right-margin* 100))
      (dolist (form forms)
        (pprint form out)
        (terpri out)))))

(defun defsystem-form-p (form)
  (and (consp form)
       (symbolp (first form))
       (string-equal (symbol-name (first form)) "DEFSYSTEM")))

(defun find-defsystem (forms name)
  (find-if (lambda (form)
             (and (defsystem-form-p form)
                  (or (null name)
                      (string-equal (princ-to-string (second form)) name))))
           forms))

(defun plist-put (plist key value)
  (if (and plist (nth-value 1 (get-properties plist (list key))))
      (progn (setf (getf plist key) value) plist)
      (append plist (list key value))))

(defun overlay-entry-key (entry)
  (let ((plat (getf entry :platform)))
    (overlay-key :os (getf plat :os) :arch (getf plat :arch) :lisp (getf plat :lisp))))

(defun resolve-overlay-parts (&key (os nil os-p) (arch nil arch-p) (lisp nil lisp-p))
  "Bare add-overlay is this machine's os and arch.
   Any supplied flag keeps only the supplied parts. NIL means this machine."
  (multiple-value-bind (local-os local-arch local-lisp) (detect-local-platform)
    (cond
      ((not (or os-p arch-p lisp-p))
       (values local-os local-arch nil))
      (t
       (values (cond ((not os-p) nil) ((null os) local-os) (t os))
               (cond ((not arch-p) nil) ((null arch) local-arch) (t arch))
               (cond ((not lisp-p) nil) ((null lisp) local-lisp) (t lisp)))))))

(defun overlay-entry (name os arch lisp)
  (let* ((key (overlay-key :os os :arch arch :lisp lisp))
         (entry-name (or name key))
         (lisp-only (and lisp (null os) (null arch)))
         (grovel (format nil "grovel/~a/" key))
         (lib (format nil "lib/~a/" key))
         (platform (append (when os (list :os os))
                           (when arch (list :arch arch))
                           (when lisp (list :lisp lisp)))))
    (append (list :name entry-name :platform platform)
            (if lisp-only
                (list :layers (list (list :role "cffi-grovel-output" :files (list grovel))))
                (list :native-paths (list lib)
                      :layers (list (list :role "cffi-grovel-output" :files (list grovel))))))))

(defun replace-overlay (overlays entry)
  (let ((name (getf entry :name))
        (key (overlay-entry-key entry)))
    (append (remove-if (lambda (existing)
                         (and (equalp (getf existing :name) name)
                              (equalp (overlay-entry-key existing) key)))
                       overlays)
            (list entry))))

(defun update-defsystem-form (form entry)
  (let* ((plist (cddr form))
         (properties (plist-put (getf plist :properties) :cl-repo
                                (plist-put (getf (getf plist :properties) :cl-repo) :overlays
                                           (replace-overlay
                                            (getf (getf (getf plist :properties) :cl-repo) :overlays)
                                            entry)))))
    (append (list (first form) (second form))
            (plist-put plist :properties properties))))

(defun primary-asd (directory name)
  (let* ((dir (uiop:ensure-directory-pathname directory))
         (files (directory (merge-pathnames "*.asd" dir))))
    (cond
      ((and name (probe-file (merge-pathnames (format nil "~a.asd" name) dir)))
       (merge-pathnames (format nil "~a.asd" name) dir))
      ((= (length files) 1) (first files))
      (name (find name files :key #'pathname-name :test #'string-equal))
      (t (error "cl-repo: expected one .asd in ~a, found ~s" dir (mapcar #'pathname-name files))))))

(defun cmd-add-overlay (directory &key name (os nil os-p) (arch nil arch-p) (lisp nil lisp-p) system)
  "Edit the project .asd. Does not publish.
   Re-running with the same name and key replaces that overlay and leaves the rest."
  (multiple-value-bind (os arch lisp)
      (apply #'resolve-overlay-parts
             (append (when os-p (list :os os))
                     (when arch-p (list :arch arch))
                     (when lisp-p (list :lisp lisp))))
    (when (and (null os) (null arch) (null lisp))
      (error "cl-repo: add-overlay needs at least one of os, arch, lisp"))
    (let* ((path (primary-asd directory (or system name)))
           (forms (read-lisp-forms path))
           (entry (overlay-entry name os arch lisp))
           (updated nil))
      (unless (some #'defsystem-form-p forms)
        (error "cl-repo: no defsystem in ~a" path))
      (setf updated
            (mapcar (lambda (form)
                      (if (and (defsystem-form-p form)
                               (or (null system)
                                   (string-equal (princ-to-string (second form)) system)
                                   (string-equal (pathname-name path) (princ-to-string (second form)))))
                          (update-defsystem-form form entry)
                          form))
                    forms))
      (write-lisp-forms path updated)
      (values path (getf entry :name) (overlay-entry-key entry)))))

(defun read-system-overlays (directory &key system)
  (let* ((path (primary-asd directory system))
         (form (find-defsystem (read-lisp-forms path) system)))
    (getf (getf (getf (cddr form) :properties) :cl-repo) :overlays)))
