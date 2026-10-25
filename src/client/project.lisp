(defpackage :cl-repository-client/project
  (:use :cl)
  (:export #:discover-project-system
           #:read-ci-env
           #:plan-sync-systems))
(in-package :cl-repository-client/project)

(defun read-lisp-forms (path)
  (with-open-file (in path :direction :input)
    (let ((*read-eval* nil)
          (*package* (find-package :cl-user)))
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            collect form))))

(defun defsystem-form-p (form)
  (and (consp form)
       (symbolp (first form))
       (string-equal (symbol-name (first form)) "DEFSYSTEM")
       (second form)))

(defun defsystem-name (form)
  (when (defsystem-form-p form)
    (let ((name (second form)))
      (etypecase name
        (string name)
        (symbol (string-downcase (symbol-name name)))))))

(defun string-suffix-p (string suffix)
  (let ((string-length (length string))
        (suffix-length (length suffix)))
    (and (>= string-length suffix-length)
         (string= string suffix :start1 (- string-length suffix-length)))))

(defun skipped-system-name-p (name)
  "Skip secondary and test systems: a slash, a \"/tests\" fragment, or a
   -test / -tests suffix."
  (let ((down (string-downcase name)))
    (or (search "/" down)
        (search "/tests" down)
        (string-suffix-p down "-tests")
        (string-suffix-p down "-test"))))

(defun top-level-asd-files (dir)
  (sort (uiop:directory-files dir "*.asd") #'string< :key #'namestring))

(defun primary-candidates (dir)
  "Alist of (system-name . defsystem-form) for primary systems in DIR."
  (let ((found nil))
    (dolist (path (top-level-asd-files dir))
      (dolist (form (read-lisp-forms path))
        (let ((name (defsystem-name form)))
          (when (and name (not (skipped-system-name-p name)))
            (push (cons name form) found)))))
    (nreverse found)))

(defun unique-system-names (candidates)
  (let ((names nil))
    (dolist (candidate candidates)
      (pushnew (car candidate) names :test #'string-equal))
    (nreverse names)))

(defun directory-leaf (dir)
  (let ((parts (pathname-directory dir)))
    (when (consp parts)
      (car (last parts)))))

(defun discover-project-system (dir)
  "Return the unique primary system name in DIR.
   Names containing \"/\", containing \"/tests\", or ending in \"-test\" or
   \"-tests\" are skipped. Several remaining names resolve to the one that
   matches the directory name; otherwise this signals a SIMPLE-ERROR."
  (check-type dir (or string pathname))
  (let* ((directory (uiop:ensure-directory-pathname dir))
         (names (unique-system-names (primary-candidates directory)))
         (leaf (directory-leaf directory)))
    (cond
      ((null names)
       (error "No primary ASDF system in ~A." (namestring directory)))
      ((null (rest names))
       (first names))
      ((and leaf (find leaf names :test #'string-equal))
       (find leaf names :test #'string-equal))
      (t
       (error "Ambiguous primary systems ~S in ~A." names (namestring directory))))))

(defun dependency-name (designator)
  (etypecase designator
    (string designator)
    (symbol (string-downcase (symbol-name designator)))))

(defun version-token (value)
  (etypecase value
    (string value)
    (integer (write-to-string value))
    (symbol (symbol-name value))))

(defun versioned-dependency-p (dep)
  (and (consp dep)
       (or (eq (first dep) :version)
           (and (or (stringp (first dep))
                    (and (symbolp (first dep)) (not (keywordp (first dep)))))
                (eq (second dep) :version)))))

(defun normalize-dependency (dep)
  "Return a string or (name . min-version), or NIL for forms this planner skips."
  (cond
    ((or (stringp dep) (and (symbolp dep) (not (keywordp dep))))
     (dependency-name dep))
    ((and (consp dep) (eq (first dep) :version) (third dep))
     (cons (dependency-name (second dep)) (version-token (third dep))))
    ((and (consp dep)
          (or (stringp (first dep))
              (and (symbolp (first dep)) (not (keywordp (first dep)))))
          (eq (second dep) :version)
          (third dep))
     (cons (dependency-name (first dep)) (version-token (third dep))))
    (t nil)))

(defun depends-on-entries (deps)
  "Normalize a :depends-on value to a list of dependency forms.
   A single (:version ...) or (name :version ...) form is one dependency."
  (cond
    ((null deps) nil)
    ((or (stringp deps) (and (symbolp deps) (not (keywordp deps))))
     (list deps))
    ((versioned-dependency-p deps)
     (list deps))
    ((consp deps) deps)
    (t nil)))

(defun normalize-depends-on (deps)
  (remove nil (mapcar #'normalize-dependency (depends-on-entries deps))))

(defun blank-string-p (value)
  (or (null value)
      (every (lambda (char)
               (member char '(#\Space #\Tab #\Newline #\Return)))
             value)))

(defun coerce-system-names (value)
  (cond
    ((null value) nil)
    ((stringp value) (list value))
    ((and (symbolp value) (not (keywordp value)))
     (list (string-downcase (symbol-name value))))
    ((consp value)
     (loop for item in value
           collect (cond
                     ((stringp item) item)
                     ((and (symbolp item) (not (keywordp item)))
                      (string-downcase (symbol-name item)))
                     (t (error "Expected a system name, got ~S." item)))))
    (t (error "Expected a system name or list of names, got ~S." value))))

(defun plist-values (plist key)
  (loop for tail on plist by #'cddr
        when (and (consp (cdr tail)) (eq (car tail) key))
          collect (cadr tail)))

(defun env-group-entries (group)
  (cond
    ((null group) nil)
    ((and (consp group) (consp (first group))) group)
    ((and (consp group) (stringp (first group))) (list group))
    (t (error "Malformed :env entry ~S." group))))

(defun choice-label (choice)
  (let ((label (first choice)))
    (etypecase label
      (string label)
      (symbol (symbol-name label)))))

(defun env-token (value)
  (etypecase value
    (null "")
    (string value)
    (symbol (symbol-name value))))

(defun env-or-default (var default)
  (let ((raw (uiop:getenv var)))
    (if (blank-string-p raw)
        (env-token default)
        (string-trim '(#\Space #\Tab #\Newline #\Return) raw))))

(defun env-entry-systems (entry)
  "Return (values install-names load-names) for one :env entry."
  (unless (and (consp entry) (stringp (first entry)))
    (error "Malformed :env entry ~S." entry))
  (let* ((var (first entry))
         (spec (rest entry))
         (systems (getf spec :systems))
         (value (env-or-default var (getf spec :default)))
         (match (find value systems :key #'choice-label :test #'string=)))
    (unless (and match (consp match))
      (error "Unknown value ~S for environment variable ~A. Expected one of ~S."
             value var (mapcar #'choice-label systems)))
    (let ((names (coerce-system-names (rest match))))
      (values (when (getf spec :install) (copy-list names))
              (when (getf spec :load-before-test) (copy-list names))))))

(defun read-ci-env (ci-plist)
  "Expand :env entries in CI-PLIST.
   Returns (values install-systems load-systems). An empty environment variable
   uses :default. A value missing from :systems signals a SIMPLE-ERROR.
   :install and :load-before-test default to NIL. Multiple :env entries append."
  (check-type ci-plist list)
  (let ((install nil)
        (load nil))
    (dolist (group (plist-values ci-plist :env))
      (dolist (entry (env-group-entries group))
        (multiple-value-bind (entry-install entry-load) (env-entry-systems entry)
          (setf install (append install entry-install)
                load (append load entry-load)))))
    (values install load)))

(defun cl-repo-plist (properties)
  (cond
    ((null properties) nil)
    ((and (consp properties) (keywordp (first properties)))
     (getf properties :cl-repo))
    ((consp properties)
     (cdr (assoc :cl-repo properties :test #'eq)))
    (t nil)))

(defun ci-plist-from-form (form)
  (getf (cl-repo-plist (getf (cddr form) :properties)) :ci))

(defun primary-defsystem-form (dir system-name)
  (or (cdr (find system-name (primary-candidates dir) :key #'car :test #'string-equal))
      (error "Primary system ~A has no defsystem form in ~A." system-name (namestring dir))))

(defun strip-qlfile-comment (line)
  (let ((pos (position #\# line)))
    (if pos (subseq line 0 pos) line)))

(defun qlfile-tokens (line)
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return)
                           (strip-qlfile-comment line)))
        (tokens nil)
        (start nil))
    (labels ((flush (end)
               (when start
                 (push (subseq text start end) tokens)
                 (setf start nil))))
      (loop for index from 0 below (length text)
            for char = (char text index)
            do (if (or (char= char #\Space) (char= char #\Tab))
                   (flush index)
                   (unless start
                     (setf start index))))
      (flush (length text)))
    (nreverse tokens)))

(defun qlot-entry (kind name ref)
  (list :kind kind :name name :ref ref))

(defun parse-qlot-tokens (tokens line)
  (let* ((head (string-downcase (first tokens)))
         (args (rest tokens))
         (kind (cond
                 ((string= head "ql") :ql)
                 ((string= head "github") :github)
                 ((string= head "git") :git)
                 ((string= head "http") :http)
                 ((string= head "local") :local)
                 ((string= head "dist") :dist)
                 (t nil))))
    (flet ((check-count (min max)
             (unless (<= min (length args) max)
               (error "Malformed ~(~A~) qlfile line ~S." kind line))))
      (cond
        ((eq kind :ql) (check-count 1 2) (qlot-entry :ql (first args) (second args)))
        ((eq kind :github) (check-count 1 2) (qlot-entry :github (first args) (second args)))
        ((eq kind :git) (check-count 1 2) (qlot-entry :git (first args) (second args)))
        ((eq kind :http) (check-count 2 2) (qlot-entry :http (first args) (second args)))
        ((eq kind :local) (check-count 1 1) (qlot-entry :local (first args) nil))
        ((eq kind :dist) (check-count 2 2) (qlot-entry :dist (first args) (second args)))
        ((null args) (qlot-entry :bare (first tokens) nil))
        (t (error "Unknown qlfile directive in ~S." line))))))

(defun parse-qlot-line (line)
  (let ((tokens (qlfile-tokens line)))
    (when tokens
      (parse-qlot-tokens tokens line))))

(defun parse-qlot-file (path)
  (let ((entries nil))
    (with-open-file (in path :direction :input)
      (loop for line = (read-line in nil nil)
            while line
            do (let ((entry (parse-qlot-line line)))
                 (when entry
                   (push entry entries)))))
    (nreverse entries)))

(defun qlot-source-path (dir)
  "qlfile.lock wins over qlfile. NIL when neither is present."
  (or (probe-file (merge-pathnames "qlfile.lock" dir))
      (probe-file (merge-pathnames "qlfile" dir))))

(defun read-project-qlot (dir)
  (let ((path (qlot-source-path dir)))
    (when path
      (parse-qlot-file path))))

(defun plan-sync-systems (dir)
  "Plan a sync of the primary system in DIR.
   Returns a plist :system :depends-on :install :load-before-test :qlot.
   :depends-on entries are strings or (name . min-version). :ci :with and
   :env :install systems go to :install; :ci :load-before-test and
   :env :load-before-test go to :load-before-test. A qlfile.lock, else a
   qlfile, supplies :qlot. Does not quickload."
  (check-type dir (or string pathname))
  (let* ((directory (uiop:ensure-directory-pathname dir))
         (system (discover-project-system directory))
         (form (primary-defsystem-form directory system))
         (ci (ci-plist-from-form form)))
    (multiple-value-bind (env-install env-load) (read-ci-env (or ci nil))
      (list :system system
            :depends-on (normalize-depends-on (getf (cddr form) :depends-on))
            :install (append (coerce-system-names (getf ci :with)) env-install)
            :load-before-test (append (coerce-system-names (getf ci :load-before-test)) env-load)
            :qlot (read-project-qlot directory)))))
