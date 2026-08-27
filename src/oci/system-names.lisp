(defpackage :cl-oci/system-names
  (:use :cl)
  (:export #:oci-package-name
           #:asdf-primary-system-name
           #:slash-system-name-p
           #:provided-oci-repositories))
(in-package :cl-oci/system-names)

(defun slash-system-name-p (name)
  "T when NAME is an ASDF slash secondary (`foo/bar`)."
  (and name (find #\/ (string name))))

(defun asdf-primary-system-name (name)
  "ASDF secondary `foo/bar` is defined in primary system `foo`."
  (let ((n (string-downcase (string name))))
    (subseq n 0 (or (position #\/ n) (length n)))))

(defun %plus-encode (name)
  "GHCR repository names cannot contain '+'. Same mapping as setup-client.sh."
  (with-output-to-string (out)
    (loop for c across name
          do (if (char= c #\+)
                 (write-string "-plus-" out)
                 (write-char c out)))))

(defun oci-package-name (name)
  "GHCR repository last component for ASDF system NAME.

   Slash secondaries live in the primary package (`foo/bar` → `foo`).
   '+' is encoded (`cl+ssl` → `cl-plus-ssl`)."
  (%plus-encode (asdf-primary-system-name name)))

(defun provided-oci-repositories (namespace provides)
  "OCI repositories that receive a full package push or blob-mount.

   Slash secondaries are recorded in `provides` metadata only — they cannot
   be GHCR path components and are already in the primary tarball."
  (let ((canonical (first provides)))
    (when canonical
      (cons (format nil "~a/~a" namespace (oci-package-name canonical))
            (loop for secondary in (rest provides)
                  unless (slash-system-name-p secondary)
                    collect (format nil "~a/~a" namespace
                                    (oci-package-name secondary)))))))
