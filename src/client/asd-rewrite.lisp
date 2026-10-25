(defpackage :cl-repository-client/asd-rewrite
  (:use :cl)
  (:export #:overlay-key
           #:add-overlay-entry))
(in-package :cl-repository-client/asd-rewrite)

(defun overlay-key (&key os arch lisp)
  "Join the non-NIL parts of OS, ARCH, and LISP with \"-\", in that order."
  (check-type os (or null string))
  (check-type arch (or null string))
  (check-type lisp (or null string))
  (format nil "~{~A~^-~}" (remove nil (list os arch lisp))))

(defun read-lisp-forms (path)
  (with-open-file (in path :direction :input)
    (let ((*read-eval* nil)
          (*package* (find-package :cl-user)))
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            collect form))))

(defun write-lisp-forms (path forms)
  (with-open-file (out path :direction :output :if-exists :supersede :if-does-not-exist :create)
    (let ((*package* (find-package :cl-user))
          (*print-case* :downcase)
          (*print-pretty* nil)
          (*print-length* nil)
          (*print-level* nil)
          (*print-circle* nil)
          (*print-readably* nil)
          (*print-base* 10)
          (*print-radix* nil))
      (dolist (form forms)
        (prin1 form out)
        (terpri out)
        (terpri out)))))

(defun defsystem-form-p (form)
  (and (consp form)
       (symbolp (first form))
       (string-equal (symbol-name (first form)) "DEFSYSTEM")))

(defun plist-replace (plist key value)
  "Return a copy of PLIST with KEY set to VALUE, preserving other keys."
  (let ((found nil)
        (out nil))
    (do ((tail plist (cddr tail)))
        ((null tail))
      (unless (and (consp tail) (consp (cdr tail)))
        (error "Malformed property list ~S." plist))
      (let ((existing (car tail))
            (existing-value (cadr tail)))
        (push existing out)
        (cond
          ((and (not found) (eq existing key))
           (push value out)
           (setf found t))
          (t (push existing-value out)))))
    (unless found
      (push key out)
      (push value out))
    (nreverse out)))

(defun upsert-overlay (overlays entry)
  "Replace the first overlay with ENTRY's :name, dropping later duplicates."
  (let ((name (getf entry :name))
        (replaced nil)
        (out nil))
    (dolist (overlay overlays)
      (cond
        ((and (consp overlay) (equal (getf overlay :name) name))
         (unless replaced
           (push entry out)
           (setf replaced t)))
        (t (push overlay out))))
    (unless replaced
      (push entry out))
    (nreverse out)))

(defun platform-spec (os arch lisp)
  (append (and os (list :os os))
          (and arch (list :arch arch))
          (and lisp (list :lisp lisp))))

(defun directory-mapping (source dest)
  (list (cons source dest)))

(defun overlay-layers (key os arch)
  "OS or ARCH selects the native-library and grovel layers. Lisp alone selects grovel."
  (let ((grovel (list :role "cffi-grovel-output"
                      :files (directory-mapping (format nil "grovel/~A/" key) "grovel/"))))
    (if (or os arch)
        (list (list :role "native-library"
                    :files (directory-mapping (format nil "lib/~A/" key) "lib/"))
              grovel)
        (list grovel))))

(defun overlay-entry (name os arch lisp)
  (let* ((key (overlay-key :os os :arch arch :lisp lisp))
         (entry-name (if (and name (plusp (length name))) name key)))
    (when (zerop (length key))
      (error "Overlay key is empty; pass :os, :arch, and/or :lisp."))
    (list :name entry-name
          :platform (platform-spec os arch lisp)
          :layers (overlay-layers key os arch))))

(defun install-overlay (form entry)
  (let* ((options (cddr form))
         (properties (getf options :properties))
         (repo (getf properties :cl-repo))
         (overlays (upsert-overlay (getf repo :overlays) entry))
         (new-repo (plist-replace repo :overlays overlays))
         (new-properties (plist-replace properties :cl-repo new-repo))
         (new-options (plist-replace options :properties new-properties)))
    (list* (first form) (second form) new-options)))

(defun add-overlay-entry (asd-path &key name os arch lisp)
  "Write one overlay into the first defsystem in ASD-PATH.
   The overlay is stored at :properties (:cl-repo (:overlays ...)). An existing
   overlay with the same :name is replaced. NAME defaults to OVERLAY-KEY.
   Returns the overlay entry."
  (check-type asd-path (or string pathname))
  (check-type name (or null string))
  (check-type os (or null string))
  (check-type arch (or null string))
  (check-type lisp (or null string))
  (let* ((forms (read-lisp-forms asd-path))
         (entry (overlay-entry name os arch lisp))
         (seen nil)
         (updated (mapcar (lambda (form)
                            (if (and (not seen) (defsystem-form-p form))
                                (progn
                                  (setf seen t)
                                  (install-overlay form entry))
                                form))
                          forms)))
    (unless seen
      (error "No defsystem form in ~A." asd-path))
    (write-lisp-forms asd-path updated)
    entry))
