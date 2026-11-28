;;;; The client tree (cl-repository#207).
;;;;
;;;; setup-client extracts each package into DEST/NAME-VERSION/
;;;; (~/.cl-repository-client/http-backend-async-0.2.32/), and an upgrade is
;;;; staged additively, so running sessions keep their files: DEST ends up
;;;; with several releases of one dependency. Registered as one (:tree DEST),
;;;; ASDF takes the first .asd it meets in path order, the oldest release
;;;; (http-backend-async 0.2.28 over 0.2.32), or another package's bundled
;;;; copy. CLIENT-TREE-COPIES maps each such system to NAME.asd in its newest
;;;; NAME-VERSION directory.
;;;;
;;;; This file uses only CL, UIOP, ASDF and version-utils.lisp: roswell/cl-repo.ros
;;;; loads both as source before it loads the client, and calls
;;;; INSTALL-CLIENT-TREE-SEARCH, so the client image itself loads the newest
;;;; releases. Once the client runs, REFRESH-OWN-COPIES folds the same mapping
;;;; into *OWN-COPIES*, which test and run images get too.

(defpackage :cl-repository-client/client-tree
  (:use :cl)
  (:import-from :cl-repository-client/version-utils #:version<)
  (:export #:release-directory-name
           #:newest-release-directories
           #:client-tree-copies
           #:*client-tree-copies*
           #:client-tree-search
           #:install-client-tree-search
           #:uninstall-client-tree-search))
(in-package :cl-repository-client/client-tree)

(defun %version-start-p (string)
  "STRING starts like a release version: digits, then its end or one of . - + _
   (\"0.2.32\", \"3.1\", \"20240503-8514d8e\"; not \"2d-1.0\")."
  (let ((end (position-if-not #'digit-char-p string)))
    (and (plusp (length string))
         (digit-char-p (char string 0))
         (or (null end) (find (char string end) ".-+_"))
         t)))

(defun release-directory-name (leaf &optional directory)
  "(values NAME VERSION) of a client tree directory named NAME-VERSION, or NIL
   when no hyphen in LEAF is followed by a version (a git-hash version such as
   cl+ssl-e9de2ca…). A name may itself hold a hyphen and digits
   (cl-repo-207-a-0.2.32): with DIRECTORY, the split whose NAME.asd is in it
   wins, else the first one."
  (let ((splits (loop for start = 0 then (1+ pos)
                      for pos = (position #\- leaf :start start)
                      while pos
                      when (and (plusp pos) (%version-start-p (subseq leaf (1+ pos))))
                        collect (cons (subseq leaf 0 pos) (subseq leaf (1+ pos))))))
    (let ((split (or (and directory
                          (find-if (lambda (split)
                                     (probe-file (merge-pathnames (format nil "~a.asd" (car split))
                                                                  directory)))
                                   splits))
                     (first splits))))
      (and split (values (car split) (cdr split))))))

(defun newest-release-directories (tree)
  "Hash table NAME → (directory . version): the newest NAME-VERSION directory
   of TREE for each NAME (VERSION< order, so 0.2.100 is newer than 0.2.32)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (dir (ignore-errors (uiop:subdirectories tree)) table)
      (let ((leaf (car (last (pathname-directory dir)))))
        (multiple-value-bind (name version) (and (stringp leaf) (release-directory-name leaf dir))
          (when name
            (let ((best (gethash name table)))
              (when (or (null best) (version< (cdr best) version))
                (setf (gethash name table) (cons dir version))))))))))

(defun %truename-directory (dir)
  (and dir (uiop:truename* (uiop:ensure-directory-pathname dir))))

(defun client-tree-copies (tree &key keep)
  "Alist primary system name → namestring of NAME.asd in NAME's newest
   NAME-VERSION directory of TREE, sorted by name, for each NAME the current
   source registry resolves to another .asd inside TREE: an older release or
   a bundled copy in another package. A system resolved outside TREE (a
   project checkout, an install tree) or inside one of the KEEP directories
   (the running client's own, which its other systems must match) is left
   alone."
  (let ((tree-true (%truename-directory tree))
        (keep-true (remove nil (mapcar #'%truename-directory keep))))
    (when tree-true
      (sort
       (loop for name being the hash-keys of (newest-release-directories tree-true)
               using (hash-value entry)
             for own = (probe-file (merge-pathnames (format nil "~a.asd" name) (car entry)))
             for found = (and own (asdf/source-registry:sysdef-source-registry-search name))
             for found-true = (and found (uiop:truename* found))
             when (and found-true
                       (uiop:subpathp found-true tree-true)
                       (notany (lambda (dir) (uiop:subpathp found-true dir)) keep-true)
                       (not (uiop:pathname-equal found-true own)))
               collect (cons name (namestring own)))
       #'string< :key #'car))))

(defvar *client-tree-copies* '()
  "The mapping INSTALL-CLIENT-TREE-SEARCH installed (CLIENT-TREE-COPIES).")

(defun client-tree-search (name)
  "ASDF search function: NAME.asd of NAME's primary system in its newest
   client tree release, when *CLIENT-TREE-COPIES* maps it; else NIL."
  (let ((file (cdr (assoc (asdf:primary-system-name name) *client-tree-copies*
                          :test #'string=))))
    (and file (probe-file file))))

(defun install-client-tree-search (tree &key keep)
  "Map TREE's shadowed systems (CLIENT-TREE-COPIES) and put CLIENT-TREE-SEARCH
   first among ASDF's search functions. For roswell/cl-repo.ros, after it
   initializes the source registry and before it loads the client. Returns
   the mapping."
  (setf *client-tree-copies* (client-tree-copies tree :keep keep))
  (setf asdf:*system-definition-search-functions*
        (cons 'client-tree-search
              (remove 'client-tree-search asdf:*system-definition-search-functions*)))
  *client-tree-copies*)

(defun uninstall-client-tree-search ()
  "Drop the launcher's mapping: computed for the launcher's registry, it would
   shadow a project checkout once the client registers a project."
  (setf *client-tree-copies* '())
  (setf asdf:*system-definition-search-functions*
        (remove 'client-tree-search asdf:*system-definition-search-functions*)))
