;;;; Shared helpers for canned CI (no cl-repo: symbols — safe to load before the client).
;;;;
;;;; .asd convention:
;;;;   :properties (:cl-repo (:ci (:with (...) :sources (...) :also-tests t
;;;;                               :load-before-test (...) :record-versions (...))))
;;;;
;;;; Optional hooks (after client load): scripts/ci/{pre,post}-{install,test,publish}.lisp

(defpackage :cl-repository-ci-lib
  (:use :cl)
  (:export #:nonempty-env
           #:split-ws
           #:test-system-name-p
           #:secondary-system-name-p
           #:discover-primary-systems
           #:discover-primary-system
           #:system-cl-repo-properties
           #:system-ci-plist
           #:ci-also-tests
           #:ci-with
           #:ci-sources
           #:ci-load-before-test
           #:ci-record-versions
           #:hooks-directory
           #:hook-file
           #:format-tree-registry
           #:drop-dirs-from-registry
           #:client-bootstrap-registry
           #:discover-asd-system-names
           #:clear-checkout-systems
           #:*extra-with*
           #:*extra-sources*))
(in-package :cl-repository-ci-lib)

(defvar *extra-with* nil
  "Hook-supplied extra systems, merged into :ci :with.")

(defvar *extra-sources* nil
  "Hook-supplied source pins, merged into :ci :sources.")

(defun nonempty-env (name)
  (let ((v (uiop:getenv name)))
    (when (and v (plusp (length (string-trim '(#\Space #\Tab #\Newline #\Return) v))))
      (string-trim '(#\Space #\Tab #\Newline #\Return) v))))

(defun split-ws (s)
  (when (and s (plusp (length s)))
    (loop for start = 0 then (1+ end)
          for end = (position-if (lambda (c) (member c '(#\Space #\Tab #\, #\Newline)))
                                 s :start start)
          for part = (string-trim '(#\Space #\Tab #\,) (subseq s start end))
          unless (string= part "") collect part
          while end)))

(defun test-system-name-p (name)
  "True for ASDF names that look like test systems."
  (let* ((n (string-downcase name))
         (len (length n)))
    (flet ((suffixp (suffix)
             (let ((slen (length suffix)))
               (and (>= len slen)
                    (string= n suffix :start1 (- len slen))))))
      (or (search "/tests" n)
          (search "/test" n)
          (suffixp "-test")
          (suffixp "-tests")))))

(defun secondary-system-name-p (name)
  "Skip test systems and slash-names (foo/tests, foo/conformance)."
  (or (test-system-name-p name)
      (find #\/ name)))

(defun defsystem-name (form)
  (when (and (listp form)
             (symbolp (first form))
             (string-equal "DEFSYSTEM" (symbol-name (first form)))
             (second form))
    (etypecase (second form)
      (string (second form))
      (symbol (string-downcase (symbol-name (second form)))))))

(defun format-tree-registry (dir &key windows)
  "One-entry CL_SOURCE_REGISTRY tree search for DIR."
  (format nil "~a//~a"
          (string-right-trim '(#\/ #\\) (namestring dir))
          (if windows ";" ":")))

(defun %registry-entry-dir (entry)
  (let ((s (string-trim '(#\Space #\Tab) entry)))
    (when (and (>= (length s) 2)
               (string= s "//" :start1 (- (length s) 2)))
      (setf s (subseq s 0 (- (length s) 2))))
    (uiop:ensure-directory-pathname (string-right-trim '(#\/ #\\) s))))

(defun drop-dirs-from-registry (registry dirs)
  "Remove DIR tree entries from a CL_SOURCE_REGISTRY string. Preserves the
   setup-lisp separator (`:` vs Windows `;`)."
  (when (and registry (plusp (length registry)))
    (let* ((windows (find #\; registry))
           (sep (if windows ";" ":"))
           (parts (remove-if (lambda (s) (zerop (length s)))
                             (uiop:split-string registry :separator sep)))
           (drop (loop for d in dirs
                       when (and d (plusp (length (string d))))
                         collect (%registry-entry-dir (namestring d))))
           (kept (remove-if
                  (lambda (part)
                    (let ((p (%registry-entry-dir part)))
                      (some (lambda (d) (uiop:pathname-equal p d)) drop)))
                  parts)))
      (when kept
        (format nil (if windows "~{~a~^;~};" "~{~a~^:~}:") kept)))))

(defun client-bootstrap-registry ()
  "CL_SOURCE_REGISTRY without the consumer checkout.
   setup-lisp writes checkout-first; that shadows bundled client deps."
  (let ((registry (nonempty-env "CL_SOURCE_REGISTRY")))
    (when registry
      (drop-dirs-from-registry
       registry
       (list (uiop:getcwd) (nonempty-env "GITHUB_WORKSPACE"))))))

(defun discover-asd-system-names (source-dir)
  "All defsystem names from top-level *.asd under SOURCE-DIR."
  (let ((names nil)
        (*read-eval* nil)
        (*package* (find-package :cl-user))
        (dir (uiop:ensure-directory-pathname source-dir)))
    (dolist (asd-path (directory (merge-pathnames "*.asd" dir)))
      (handler-case
          (with-open-file (s asd-path :direction :input :if-does-not-exist nil)
            (when s
              (loop for form = (read s nil :eof)
                    until (eq form :eof)
                    for name = (defsystem-name form)
                    when name do (pushnew name names :test #'string=))))
        (error () nil)))
    (nreverse names)))

(defun clear-checkout-systems (&optional (source-dir (uiop:getcwd)))
  "Drop ASDF registrations so the next find-system re-reads checkout asds."
  (dolist (name (discover-asd-system-names source-dir))
    (asdf:clear-system name)))

(defun discover-primary-systems (source-dir)
  "Primary system names from top-level *.asd under SOURCE-DIR (tests/secondaries omitted)."
  (remove-if #'secondary-system-name-p (discover-asd-system-names source-dir)))

(defun discover-primary-system (&optional (source-dir (uiop:getcwd)))
  "Pick the unique primary system, or the one matching the directory name."
  (let* ((dir (uiop:ensure-directory-pathname source-dir))
         (names (discover-primary-systems dir))
         (dir-name (car (last (pathname-directory dir)))))
    (cond
      ((null names)
       (error "No primary ASDF system in ~a (*.asd). Set input system / CL_REPO_SYSTEM."
              dir))
      ((= (length names) 1)
       (first names))
      ((and dir-name (find dir-name names :test #'string-equal))
       (find dir-name names :test #'string-equal))
      (t
       (error "Ambiguous checkout systems ~s in ~a. Set input system / CL_REPO_SYSTEM."
              names dir)))))

(defun system-cl-repo-properties (system)
  "Extract :cl-repo from SYSTEM's :properties (plist or alist)."
  (let ((props (slot-value system (find-symbol (string '#:properties)
                                               (find-package :asdf/component)))))
    (etypecase (first props)
      (keyword (getf props :cl-repo))
      (cons (cdr (assoc :cl-repo props :test #'eq)))
      (null nil))))

(defun system-ci-plist (system-or-name)
  "Return the :cl-repo :ci plist, or NIL."
  (let* ((system (if (typep system-or-name 'asdf:system)
                     system-or-name
                     (asdf:find-system system-or-name)))
         (cl-repo (system-cl-repo-properties system)))
    (getf cl-repo :ci)))

(defun ci-also-tests (ci)
  (getf ci :also-tests t))

(defun ci-with (ci &optional extra)
  (delete-duplicates
   (append (mapcar (lambda (s) (string-downcase (string s)))
                   (uiop:ensure-list (getf ci :with)))
           (mapcar (lambda (s) (string-downcase (string s)))
                   (uiop:ensure-list extra))
           (mapcar (lambda (s) (string-downcase (string s)))
                   (uiop:ensure-list *extra-with*)))
   :test #'string=))

(defun ci-sources (ci)
  (append (copy-list (getf ci :sources))
          (copy-list *extra-sources*)))

(defun ci-load-before-test (ci)
  (mapcar (lambda (s) (string-downcase (string s)))
          (uiop:ensure-list (getf ci :load-before-test))))

(defun ci-record-versions (ci)
  "List of (system-name . env-var) from :record-versions."
  (loop for entry in (getf ci :record-versions)
        collect (etypecase entry
                  (cons (cons (string-downcase (string (car entry)))
                              (string (cdr entry)))))))

(defun hooks-directory ()
  (uiop:ensure-directory-pathname
   (or (nonempty-env "CL_REPO_CI_HOOKS_DIR")
       (merge-pathnames "scripts/ci/" (uiop:getcwd)))))

(defun hook-file (phase)
  (merge-pathnames (format nil "~a.lisp" phase) (hooks-directory)))
