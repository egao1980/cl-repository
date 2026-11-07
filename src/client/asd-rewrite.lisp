(defpackage :cl-repository-client/asd-rewrite
  (:use :cl)
  (:import-from :cl-repository-client/platform-resolver
                #:detect-local-platform #:overlay-key)
  (:import-from :cl-repository-client/asd-text
                #:find-defsystem-span #:plist-value-span #:splice #:print-value-at #:line-column)
  (:export #:cmd-add-overlay
           #:asd-defsystem-depends-on
           #:read-system-overlays
           #:overlay-entry-key))
(in-package :cl-repository-client/asd-rewrite)

(defun read-lisp-forms (path)
  (with-open-file (in path :direction :input)
    (let ((*read-eval* nil))
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            collect form))))

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

(defun %dep-name (dep)
  "Downcased system name of a :defsystem-depends-on entry, or NIL."
  (cond ((stringp dep) (string-downcase dep))
        ((and dep (symbolp dep)) (string-downcase (symbol-name dep)))
        ((and (consp dep) (member (first dep) '(:version :feature) :test #'string-equal))
         (%dep-name (if (string-equal (first dep) :feature) (third dep) (second dep))))
        (t nil)))

(defun asd-defsystem-depends-on (path)
  "System names in every defsystem's :DEFSYSTEM-DEPENDS-ON in the .asd at PATH,
read without evaluating it (*READ-EVAL* NIL). Those systems must be present
before ASDF can load the file, so they can't come from walking a loaded
system. NIL when the file can't be read statically (#. or an unknown package
prefix): ASDF then reports what is missing."
  (let ((forms (handler-case (read-lisp-forms path)
                 (reader-error () nil)
                 (package-error () nil))))
    (remove-duplicates
     (loop for form in forms
           when (defsystem-form-p form)
             append (remove nil (mapcar #'%dep-name
                                        (getf (cddr form) :defsystem-depends-on))))
     :test #'string=)))

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

;;; The .asd is edited as text: only the :overlays value changes (or the
;;; missing :properties / :cl-repo / :overlays is inserted), so comments,
;;; reader conditionals and layout survive.

(defun splice-overlays (text system-name overlays)
  "TEXT with SYSTEM-NAME's :properties :cl-repo :overlays set to OVERLAYS."
  (multiple-value-bind (start end) (find-defsystem-span text system-name)
    (unless start (error "cl-repo: no (defsystem ~s ...) in the .asd" system-name))
    (flet ((insert-before-close (list-start list-end col string)
             ;; before the list's closing paren; on its own line at COL unless
             ;; the list is empty
             (let ((lead (if (= list-end (+ list-start 2))
                             ""
                             (format nil "~%~a" (make-string col :initial-element #\Space)))))
               (splice text (1- list-end) (1- list-end) (concatenate 'string lead string)))))
      (multiple-value-bind (p-start p-end) (plist-value-span text start end ":properties" :skip 2)
        (if (null p-start)
            (insert-before-close start end 2
                                 (format nil ":properties (:cl-repo (:overlays ~a))"
                                         (print-value-at overlays 35)))
            (multiple-value-bind (c-start c-end) (plist-value-span text p-start p-end ":cl-repo")
              (if (null c-start)
                  (let ((col (+ (line-column text p-start) 1)))
                    (insert-before-close p-start p-end col
                                         (format nil ":cl-repo (:overlays ~a)"
                                                 (print-value-at overlays (+ col 20)))))
                  (multiple-value-bind (o-start o-end) (plist-value-span text c-start c-end ":overlays")
                    (if o-start
                        (splice text o-start o-end
                                (print-value-at overlays (line-column text o-start)))
                        (let ((col (+ (line-column text c-start) 1)))
                          (insert-before-close c-start c-end col
                                               (format nil ":overlays ~a"
                                                       (print-value-at overlays (+ col 10))))))))))))))

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
   Re-running with the same name and key replaces that overlay and leaves the rest.
   Only SYSTEM's (default: the system named after the .asd) :overlays value
   changes; the rest of the file is kept as written."
  (multiple-value-bind (os arch lisp)
      (apply #'resolve-overlay-parts
             (append (when os-p (list :os os))
                     (when arch-p (list :arch arch))
                     (when lisp-p (list :lisp lisp))))
    (when (and (null os) (null arch) (null lisp))
      (error "cl-repo: add-overlay needs at least one of os, arch, lisp"))
    (let* ((path (primary-asd directory (or system name)))
           (system-name (string-downcase (or system (pathname-name path))))
           (form (find-defsystem (read-lisp-forms path) system-name))
           (entry (overlay-entry name os arch lisp)))
      (unless form
        (error "cl-repo: no (defsystem ~s ...) in ~a" system-name path))
      (let* ((overlays (replace-overlay
                        (getf (getf (getf (cddr form) :properties) :cl-repo) :overlays)
                        entry))
             (text (splice-overlays (uiop:read-file-string path) system-name overlays)))
        (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
          (write-string text out)))
      (values path (getf entry :name) (overlay-entry-key entry)))))

(defun read-system-overlays (directory &key system)
  (let* ((path (primary-asd directory system))
         (form (find-defsystem (read-lisp-forms path) (or system (pathname-name path)))))
    (getf (getf (getf (cddr form) :properties) :cl-repo) :overlays)))
