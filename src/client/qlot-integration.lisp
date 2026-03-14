(defpackage :cl-repository-client/qlot-integration
  (:use :cl)
  (:export #:qlot-entry
           #:qlot-entry-kind
           #:qlot-entry-name
           #:qlot-entry-ref
           #:qlot-entry-raw
           #:resolve-qlot-path
           #:read-qlfile-with-path
           #:read-qlfile-lock-with-path
           #:parse-qlot-line
           #:read-qlfile
           #:read-qlfile-lock
           #:build-qlot-sync-plan
           #:qlot-installable-entry-p))
(in-package :cl-repository-client/qlot-integration)

(defstruct qlot-entry
  "Parsed qlot dependency entry."
  kind
  name
  ref
  raw)

(defun whitespace-char-p (ch)
  (or (char= ch #\Space) (char= ch #\Tab)))

(defun split-whitespace (line)
  "Split LINE by whitespace into tokens."
  (let ((tokens nil)
        (start nil))
    (labels ((flush (end)
               (when start
                 (push (subseq line start end) tokens)
                 (setf start nil))))
      (loop for i from 0 below (length line)
            for ch = (char line i)
            do (if (whitespace-char-p ch)
                   (flush i)
                   (unless start
                     (setf start i))))
      (flush (length line)))
    (nreverse tokens)))

(defun strip-comments (line)
  "Remove qlot-style comments from LINE."
  (let ((pos (position #\# line)))
    (if pos
        (subseq line 0 pos)
        line)))

(defun parse-qlot-line (line)
  "Parse one qlfile line into a QLOT-ENTRY or NIL."
  (let* ((content (string-trim '(#\Space #\Tab #\Newline #\Return)
                               (strip-comments line))))
    (when (> (length content) 0)
      (let* ((tokens (split-whitespace content))
             (kind-token (string-downcase (first tokens))))
        (cond
          ;; ql alexandria
          ((string= kind-token "ql")
           (make-qlot-entry :kind :ql
                            :name (second tokens)
                            :ref (third tokens)
                            :raw content))
          ;; github owner/repo [ref]
          ((string= kind-token "github")
           (make-qlot-entry :kind :github
                            :name (second tokens)
                            :ref (third tokens)
                            :raw content))
          ;; git https://... [ref]
          ((string= kind-token "git")
           (make-qlot-entry :kind :git
                            :name (second tokens)
                            :ref (third tokens)
                            :raw content))
          ;; Dist/source declarations are currently ignored by cl-repo onboarding.
          ((or (string= kind-token "dist")
               (string= kind-token "source")
               (string= kind-token "http"))
           nil)
          ;; Bare symbol line => Quicklisp system shorthand.
          (t
           (make-qlot-entry :kind :ql
                            :name (first tokens)
                            :ref (second tokens)
                            :raw content)))))))

(defun parse-qlot-lock-line (line)
  "Parse one qlfile.lock line into a QLOT-ENTRY or NIL.
Supports qlot-like source lines and relaxed plain forms."
  (let ((entry (parse-qlot-line line)))
    (when entry
      ;; qlfile.lock is pin-oriented: bare ql entries without ref are low quality.
      (when (and (eq (qlot-entry-kind entry) :ql)
                 (null (qlot-entry-ref entry)))
        (setf (qlot-entry-ref entry) "latest"))
      entry)))

(defun normalize-directory-pathname (path)
  "Normalize PATH into a directory pathname."
  (let ((pn (pathname path)))
    (if (or (pathname-name pn) (pathname-type pn))
        (make-pathname :name nil :type nil :defaults pn)
        pn)))

(defun parent-directory-pathname (dir)
  "Return parent directory pathname for DIR, or NIL at root."
  (let* ((norm (normalize-directory-pathname dir))
         (parts (pathname-directory norm)))
    (when (and (listp parts)
               (member (first parts) '(:absolute :relative))
               (> (length parts) 1))
      (make-pathname :directory (butlast parts)
                     :name nil
                     :type nil
                     :defaults norm))))

(defun find-nearest-file-upward (filename &optional (start-dir (uiop:getcwd)))
  "Find FILENAME at START-DIR or nearest parent directory."
  (let ((dir (normalize-directory-pathname start-dir)))
    (loop
      for candidate = (merge-pathnames filename dir)
      when (probe-file candidate) do (return candidate)
      do (let ((parent (parent-directory-pathname dir)))
           (if (or (null parent)
                   (equal (namestring parent) (namestring dir)))
               (return nil)
               (setf dir parent))))))

(defun resolve-qlot-path (explicit-path filename)
  "Resolve qlot file path.
If EXPLICIT-PATH is provided, require it to exist.
Otherwise infer by nearest-parent lookup from CWD."
  (if explicit-path
      (let ((pn (pathname explicit-path)))
        (unless (probe-file pn)
          (error "~a not found: ~a" filename pn))
        pn)
      (or (find-nearest-file-upward filename)
          (error "~a not found in current or parent directories" filename))))

(defun read-qlfile-with-path (&optional path)
  "Read qlfile and return (values entries resolved-path)."
  (let ((resolved-path (resolve-qlot-path path "qlfile")))
  (let ((entries nil))
      (with-open-file (stream resolved-path :direction :input)
      (loop for line = (read-line stream nil nil)
            while line
            do (let ((entry (parse-qlot-line line)))
                 (when entry
                   (push entry entries)))))
      (values (nreverse entries) resolved-path))))

(defun read-qlfile (&optional path)
  "Read qlfile and return parsed QLOT-ENTRY list."
  (nth-value 0 (read-qlfile-with-path path)))

(defun maybe-entry-from-lock-form (form)
  "Parse an s-expression lock FORM into QLOT-ENTRY or NIL."
  (cond
    ;; plist-style: (:kind :github :name "foo/bar" :ref "abc")
    ((and (listp form) (keywordp (first form)))
     (let* ((kind (getf form :kind (getf form :source)))
            (name (or (getf form :name) (getf form :project) (getf form :system)))
            (ref (or (getf form :ref) (getf form :revision) (getf form :version))))
       (when (and kind name)
         (make-qlot-entry :kind (intern (string-upcase (string kind)) :keyword)
                          :name name
                          :ref ref
                          :raw (prin1-to-string form)))))
    ;; pair-style: ("github" "foo/bar" "sha")
    ((and (listp form) (>= (length form) 2))
     (let* ((kind-raw (first form))
            (kind-token (string-downcase (string kind-raw)))
            (kind (cond
                    ((string= kind-token "ql") :ql)
                    ((string= kind-token "github") :github)
                    ((string= kind-token "git") :git)
                    (t nil))))
       (when kind
         (make-qlot-entry :kind kind
                          :name (string (second form))
                          :ref (when (third form) (string (third form)))
                          :raw (prin1-to-string form)))))
    (t nil)))

(defun read-qlfile-lock-with-path (&optional path)
  "Read qlfile.lock and return (values entries resolved-path).
Supports line-oriented and simple s-expression lock files."
  (let ((resolved-path (resolve-qlot-path path "qlfile.lock"))
        (entries nil))
    ;; Pass 1: line-oriented lock format
    (with-open-file (stream resolved-path :direction :input)
      (loop for line = (read-line stream nil nil)
            while line
            do (let ((entry (parse-qlot-lock-line line)))
                 (when entry
                   (push entry entries)))))
    (when entries
      (return-from read-qlfile-lock-with-path
        (values (nreverse entries) resolved-path)))
    ;; Pass 2: s-expression lock format
    (with-open-file (stream resolved-path :direction :input)
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (let ((entry (maybe-entry-from-lock-form form)))
                 (when entry
                   (push entry entries)))))
    (if entries
        (values (nreverse entries) resolved-path)
        (error "Could not parse qlfile.lock format at ~a" resolved-path))))

(defun read-qlfile-lock (&optional path)
  "Read qlfile.lock and return parsed QLOT-ENTRY list."
  (nth-value 0 (read-qlfile-lock-with-path path)))

(defun qlot-kind-rank (kind)
  "Stable rank for deterministic sync planning."
  (case kind
    (:ql 0)
    (:github 1)
    (:git 2)
    (t 9)))

(defun qlot-entry-key (entry)
  "Deterministic dedupe key for ENTRY."
  (format nil "~a|~a" (string-downcase (symbol-name (qlot-entry-kind entry)))
          (string-downcase (or (qlot-entry-name entry) ""))))

(defun dedupe-qlot-entries (entries)
  "Deduplicate entries by kind+name, preferring entries with explicit ref."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (let* ((key (qlot-entry-key entry))
             (existing (gethash key table)))
        (setf (gethash key table)
              (cond
                ((null existing) entry)
                ((and (qlot-entry-ref entry) (null (qlot-entry-ref existing))) entry)
                (t existing)))))
    (loop for value being the hash-values of table collect value)))

(defun qlot-entry< (left right)
  "Deterministic ordering for sync plan."
  (let ((lr (qlot-kind-rank (qlot-entry-kind left)))
        (rr (qlot-kind-rank (qlot-entry-kind right))))
    (if (/= lr rr)
        (< lr rr)
        (string< (string-downcase (or (qlot-entry-name left) ""))
                 (string-downcase (or (qlot-entry-name right) ""))))))

(defun build-qlot-sync-plan (entries)
  "Normalize and deterministically order qlot ENTRIES."
  (sort (dedupe-qlot-entries entries) #'qlot-entry<))

(defun qlot-installable-entry-p (entry)
  "Return T when ENTRY maps directly to cl-repo install."
  (eq (qlot-entry-kind entry) :ql))
