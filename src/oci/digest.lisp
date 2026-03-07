(defpackage :cl-oci/digest
  (:use :cl)
  (:import-from :ironclad
                #:make-digest
                #:update-digest
                #:produce-digest
                #:byte-array-to-hex-string)
  (:import-from :babel #:string-to-octets)
  (:import-from :cl-oci/conditions
                #:oci-parse-error
                #:oci-digest-mismatch)
  (:export #:digest
           #:digest-algorithm
           #:digest-hex
           #:make-oci-digest
           #:compute-digest
           #:verify-digest
           #:parse-digest
           #:format-digest
           #:digest-equal))
(in-package :cl-oci/digest)

(defclass digest ()
  ((algorithm :type string :initarg :algorithm :accessor digest-algorithm)
   (hex :type string :initarg :hex :accessor digest-hex)))

(defun make-oci-digest (algorithm hex)
  (make-instance 'digest :algorithm algorithm :hex hex))

(defmethod print-object ((d digest) stream)
  (print-unreadable-object (d stream :type t)
    (format stream "~a:~a" (digest-algorithm d) (digest-hex d))))

(defun compute-digest (data &key (algorithm "sha256"))
  "Compute a digest of DATA (octet vector or string). Returns a DIGEST instance."
  (let* ((octets (etypecase data
                   ((simple-array (unsigned-byte 8) (*)) data)
                   (string (babel:string-to-octets data :encoding :utf-8))
                   (vector (coerce data '(simple-array (unsigned-byte 8) (*))))))

         (digest-obj (ironclad:make-digest (intern (string-upcase algorithm) :keyword)))
         (_ (ironclad:update-digest digest-obj octets))
         (result (ironclad:produce-digest digest-obj)))
    (declare (ignore _))
    (make-oci-digest algorithm (ironclad:byte-array-to-hex-string result))))

(defun parse-digest (digest-string)
  "Parse a digest string like 'sha256:abcdef...' into a DIGEST instance."
  (let ((pos (position #\: digest-string)))
    (unless pos
      (error 'oci-parse-error :message (format nil "Invalid digest format: ~a" digest-string)))
    (make-oci-digest (subseq digest-string 0 pos)
                     (subseq digest-string (1+ pos)))))

(defun format-digest (digest)
  "Format a DIGEST instance as 'algorithm:hex' string."
  (format nil "~a:~a" (digest-algorithm digest) (digest-hex digest)))

(defun digest-equal (a b)
  "Compare two digests for equality."
  (and (string= (digest-algorithm a) (digest-algorithm b))
       (string= (digest-hex a) (digest-hex b))))

(defun verify-digest (data digest)
  "Verify that DATA matches DIGEST. Signals OCI-DIGEST-MISMATCH on failure."
  (let ((computed (compute-digest data :algorithm (digest-algorithm digest))))
    (unless (digest-equal computed digest)
      (error 'oci-digest-mismatch
             :message "Digest verification failed"
             :expected (format-digest digest)
             :actual (format-digest computed)))
    t))
