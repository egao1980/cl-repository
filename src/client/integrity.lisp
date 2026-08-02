(defpackage :cl-repository-client/integrity
  (:use :cl)
  (:import-from :cl-oci/runtime #:*quiet* #:msg)
  (:import-from :cl-oci/digest #:compute-file-digest #:format-digest)
  (:import-from :cl-repository-client/atomic-file #:with-atomic-output-file #:read-sexp-file)
  (:export #:record-file-manifest
           #:verify-installed-system
           #:verify-all-systems
           #:verification-result
           #:verification-result-name
           #:verification-result-version
           #:verification-result-status
           #:verification-result-modified-files
           #:verification-result-added-files
           #:verification-result-removed-files))
(in-package :cl-repository-client/integrity)

(defvar *manifest-filename* ".cl-repo-manifest.sexp"
  "Name of the per-system file integrity manifest.")

(defstruct verification-result
  "Result of verifying an installed system against its file manifest."
  name version status modified-files added-files removed-files)

;;; --- Recording ---

(defun hash-file (path)
  "Compute SHA-256 digest of a file (streaming). Returns formatted digest string."
  (format-digest (compute-file-digest path)))

(defun collect-files (directory)
  "Recursively collect all regular files under DIRECTORY.
   Returns list of relative pathname strings, sorted alphabetically.
   Excludes the manifest file itself."
  (let ((root (uiop:ensure-directory-pathname (truename directory)))
        (files nil))
    (labels ((walk (dir)
               (dolist (entry (directory (merge-pathnames uiop:*wild-file-for-directory* dir)))
                 (unless (uiop:directory-pathname-p entry)
                   (let ((rel (enough-namestring entry root)))
                     (unless (string= rel *manifest-filename*)
                       (push rel files)))))
               (dolist (subdir (uiop:subdirectories dir))
                 (walk subdir))))
      (walk root))
    (sort files #'string<)))

(defun record-file-manifest (install-dir)
  "Record SHA-256 digests of all files in INSTALL-DIR to a manifest file.
   Called after system extraction is complete."
  (let* ((dir (uiop:ensure-directory-pathname install-dir))
         (manifest-path (merge-pathnames *manifest-filename* dir))
         (files (collect-files dir))
         (entries (mapcar (lambda (rel)
                            (cons rel (hash-file (merge-pathnames rel dir))))
                          files)))
    (with-atomic-output-file (s manifest-path)
      (format s ";;; cl-repo file manifest -- auto-generated, do not edit~%")
      (let ((*print-case* :downcase))
        (prin1 `((:manifest-version . 1)
                 (:files . ,entries))
               s))
      (terpri s))
    (msg "~&  Recorded file manifest (~d files)~%" (length entries))
    entries))

;;; --- Verification ---

(defun load-manifest (install-dir)
  "Load file manifest from INSTALL-DIR. Returns alist of (rel-path . digest) or NIL."
  (let ((path (merge-pathnames *manifest-filename*
                               (uiop:ensure-directory-pathname install-dir))))
    (handler-case
        (cdr (assoc :files (read-sexp-file path)))
      (error () nil))))

(defun verify-installed-system (install-dir &key name version)
  "Verify files in INSTALL-DIR against its manifest.
   Returns a VERIFICATION-RESULT."
  (let* ((dir (uiop:ensure-directory-pathname install-dir))
         (manifest (load-manifest dir)))
    (unless manifest
      (return-from verify-installed-system
        (make-verification-result :name name :version version :status :no-manifest)))
    (let ((manifest-ht (make-hash-table :test 'equal))
          (modified nil)
          (added nil)
          (removed nil))
      ;; Index manifest entries
      (dolist (entry manifest)
        (setf (gethash (car entry) manifest-ht) (cdr entry)))
      ;; Check current files on disk
      (dolist (rel (collect-files dir))
        (let ((expected (gethash rel manifest-ht)))
          (cond
            ((null expected)
             (push rel added))
            (t
             (let ((actual (hash-file (merge-pathnames rel dir))))
               (unless (string= expected actual)
                 (push rel modified)))
             (remhash rel manifest-ht)))))
      ;; Remaining entries in ht = removed files
      (maphash (lambda (k v) (declare (ignore v)) (push k removed)) manifest-ht)
      (make-verification-result
       :name name
       :version version
       :status (if (and (null modified) (null added) (null removed)) :ok :modified)
       :modified-files (sort modified #'string<)
       :added-files (sort added #'string<)
       :removed-files (sort removed #'string<)))))

(defun verify-all-systems (systems-root &key system-name)
  "Verify all installed systems under SYSTEMS-ROOT (or just SYSTEM-NAME).
   Skips symlinked system directories (provides aliases).
   Returns list of VERIFICATION-RESULT."
  (let ((root systems-root)
        (results nil))
    (unless (probe-file root)
      (return-from verify-all-systems nil))
    (dolist (sys-dir (uiop:subdirectories root))
      (let ((name (car (last (pathname-directory sys-dir)))))
        ;; Skip symlinked dirs (provides aliases)
        (when (equal (namestring sys-dir) (namestring (truename sys-dir)))
          (when (or (null system-name) (string-equal system-name name))
            (dolist (ver-dir (uiop:subdirectories sys-dir))
              (let ((ver (car (last (pathname-directory ver-dir)))))
                (push (verify-installed-system ver-dir :name name :version ver)
                      results)))))))
    (nreverse results)))
