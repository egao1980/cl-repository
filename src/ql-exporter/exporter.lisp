(defpackage :cl-repository-ql-exporter/exporter
  (:use :cl)
  (:import-from :dexador)
  (:import-from :babel #:string-to-octets)
  (:import-from :cl-oci/runtime #:*quiet* #:*dry-run* #:msg)
  (:import-from :cl-oci-client/registry #:registry #:make-registry)
  (:import-from :cl-oci-client/push #:push-blob-check-and-push #:push-manifest)
  (:import-from :cl-oci/media-types #:+oci-image-manifest-v1+ #:+oci-image-index-v1+)
  (:import-from :cl-repository-ql-exporter/dist-parser
                #:ql-dist #:ql-dist-archive-base-url
                #:ql-release #:ql-release-project #:ql-release-url #:ql-release-prefix
                #:ql-system #:ql-system-project
                #:fetch-and-parse-dist)
  (:import-from :cl-repository-ql-exporter/repackager
                #:repackage-project #:repackage-result
                #:repackage-result-index-json #:repackage-result-index-digest
                #:repackage-result-manifest-json #:repackage-result-manifest-digest
                #:repackage-result-blobs)
  (:import-from :cl-repository-ql-exporter/incremental #:manifest-exists-in-registry-p)
  (:export #:export-dist
           #:export-project-to-registry))
(in-package :cl-repository-ql-exporter/exporter)

(defun download-archive (url)
  "Download a .tgz archive, return as octet vector."
  (let ((body (dex:get url :force-binary t)))
    (etypecase body
      ((vector (unsigned-byte 8)) body)
      (string (babel:string-to-octets body :encoding :latin-1)))))

(defun version-from-prefix (prefix)
  "Extract a version tag from a QL release prefix like 'alexandria-20260101-git'."
  (let ((pos (position #\- prefix)))
    (if pos (subseq prefix (1+ pos)) prefix)))

(defun systems-for-project (all-systems project-name)
  "Filter systems list for a specific project."
  (remove-if-not (lambda (s) (string= (ql-system-project s) project-name)) all-systems))

(defun export-project-to-registry (registry repository release systems &key version)
  "Export a single project to the registry. Returns T on success."
  (let* ((project-name (ql-release-project release))
         (archive-url (ql-release-url release))
         (ver (or version (version-from-prefix (ql-release-prefix release)))))
    (msg "~&  Downloading ~a..." project-name)
    (force-output)
    (let ((archive-data (handler-case (download-archive archive-url)
                          (error (e)
                            (msg " FAILED: ~a~%" e)
                            (return-from export-project-to-registry nil)))))
      (msg " ~d bytes~%" (length archive-data))
      (let ((result (repackage-project archive-data release systems :version ver)))
        (dolist (blob-pair (repackage-result-blobs result))
          (push-blob-check-and-push registry repository
                                    (cdr blob-pair) (car blob-pair)))
        (push-manifest registry repository
                       (repackage-result-manifest-digest result)
                       (repackage-result-manifest-json result)
                       :content-type +oci-image-manifest-v1+)
        (push-manifest registry repository ver
                       (repackage-result-index-json result)
                       :content-type +oci-image-index-v1+)
        (msg "~&  Pushed ~a:~a~%" repository ver)
        t))))

(defun export-dist (dist-url target-registry-url
                    &key (namespace "cl-systems")
                         filter
                         incremental
                         dry-run)
  "Export a Quicklisp dist to an OCI registry.
   DIST-URL is the URL to distinfo.txt.
   TARGET-REGISTRY-URL is the registry URL (e.g. 'http://localhost:5050').
   NAMESPACE is the repository namespace prefix.
   FILTER is a predicate (lambda (project-name) -> boolean), or a comma-separated string.
   INCREMENTAL if true, skip already-pushed projects.
   DRY-RUN if true, print what would be pushed without pushing.
   Also respects *dry-run* and *quiet*."
  (let ((*dry-run* (or *dry-run* dry-run)))
    (msg "~&Fetching dist metadata from ~a...~%" dist-url)
    (multiple-value-bind (dist releases systems) (fetch-and-parse-dist dist-url)
      (declare (ignore dist))
      (let* ((registry (make-registry target-registry-url))
             (filter-fn (make-filter-fn filter))
             (total (length releases))
             (processed 0)
             (skipped 0)
             (failed 0))
        (msg "~&Found ~d projects, ~d systems~%" total (length systems))
        (dolist (release releases)
          (let* ((project-name (ql-release-project release))
                 (repository (format nil "~a/~a" namespace project-name))
                 (ver (version-from-prefix (ql-release-prefix release))))
            (cond
              ((and filter-fn (not (funcall filter-fn project-name)))
               (incf skipped))
              (*dry-run*
               (msg "~&  [dry-run] Would push ~a:~a~%" repository ver)
               (incf processed))
              ((and incremental (manifest-exists-in-registry-p registry repository ver))
               (msg "~&  [skip] ~a:~a already exists~%" repository ver)
               (incf skipped))
              (t
               (let ((proj-systems (systems-for-project systems project-name)))
                 (if (export-project-to-registry registry repository release proj-systems
                                                 :version ver)
                     (incf processed)
                     (incf failed)))))))
        (msg "~&Export complete: ~d pushed, ~d skipped, ~d failed (of ~d total)~%"
             processed skipped failed total)))))

(defun make-filter-fn (filter)
  "Make a filter predicate. FILTER can be NIL, a function, or a comma-separated string."
  (etypecase filter
    (null nil)
    (function filter)
    (string (let ((names (mapcar (lambda (s) (string-trim " " s))
                                 (uiop:split-string filter :separator ","))))
              (lambda (name) (member name names :test #'string-equal))))))
