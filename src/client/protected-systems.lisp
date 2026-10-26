(defpackage :cl-repository-client/protected-systems
  (:use :cl)
  (:export #:*protected-system-prefixes*
           #:*protect-loaded-systems*
           #:*loaded-systems-snapshot*
           #:snapshot-loaded-systems
           #:ensure-snapshot
           #:implementation-system-p
           #:system-protected-p))
(in-package :cl-repository-client/protected-systems)

(defvar *protected-system-prefixes*
  '("swank" "slynk")
  "System name prefixes that should not be updated or reinstalled.
   Covers both the main system and subsystems (e.g. swank/sbcl, slynk/mrepl).
   A prefix protects only when the corresponding package is present in the image.")

(defvar *protect-loaded-systems* t
  "When true, systems captured in the loaded-systems snapshot are protected from updates.")

(defvar *loaded-systems-snapshot* nil
  "Hash-set of system names (strings) captured by SNAPSHOT-LOADED-SYSTEMS.
   NIL means snapshot not yet taken.")

(defun snapshot-loaded-systems ()
  "Capture all currently registered ASDF systems into *LOADED-SYSTEMS-SNAPSHOT*.
   Typically called once on first use of load-system or cmd-update."
  (let ((ht (make-hash-table :test 'equal)))
    (dolist (sys (asdf:registered-systems))
      (setf (gethash (string-downcase sys) ht) t))
    (setf *loaded-systems-snapshot* ht)))

(defun ensure-snapshot ()
  "Take snapshot if *PROTECT-LOADED-SYSTEMS* is T and no snapshot exists yet."
  (when (and *protect-loaded-systems* (null *loaded-systems-snapshot*))
    (snapshot-loaded-systems)))

(defun prefix-matches-p (name prefix)
  "Return T when NAME matches PREFIX exactly or as a parent system (prefix/)."
  (or (string= name prefix)
      (and (> (length name) (length prefix))
           (string= name prefix :end1 (length prefix))
           (char= (char name (length prefix)) #\/))))

(defun implementation-home ()
  "Directory of this Lisp's bundled systems, or NIL."
  #+sbcl
  (let ((home (uiop:getenv "SBCL_HOME")))
    (when (and home (plusp (length home)))
      (uiop:ensure-directory-pathname home)))
  #-sbcl nil)

(defun implementation-system-p (system-name)
  "True when SYSTEM-NAME ships with this Lisp or with ASDF.
   uiop and asdf are the host ASDF. On SBCL, contrib/*.asd (sb-posix,
   sb-rotate-byte, and the other contribs) are the implementation.
   A third-party name that merely starts with sb- is not included unless
   that asd is actually in the contrib directory."
  (let ((name (string-downcase (string system-name))))
    (or (and (member name '("asdf" "uiop") :test #'string=) t)
        (let ((home (implementation-home)))
          (and home
               (or (probe-file (merge-pathnames (format nil "contrib/~a.asd" name) home))
                   (probe-file (merge-pathnames
                                (format nil "contrib/~a/~a.asd" name name)
                                home)))
               t)))))

(defun system-protected-p (system-name)
  "Return T when SYSTEM-NAME should not be updated/reinstalled.
   Protected if:
   1. Name matches a prefix from *PROTECTED-SYSTEM-PREFIXES* AND that prefix's
      package is present in the image, OR
   2. *PROTECT-LOADED-SYSTEMS* is T and name is in the snapshot."
  (let ((name (string-downcase (string system-name))))
    (or
     (some (lambda (prefix)
             (and (prefix-matches-p name prefix)
                  (find-package (string-upcase prefix))))
           *protected-system-prefixes*)
     (and *protect-loaded-systems*
          *loaded-systems-snapshot*
          (gethash name *loaded-systems-snapshot*)))))
