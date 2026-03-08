(defpackage :cl-repository-packager/layer-builder
  (:use :cl)
  (:import-from :babel #:string-to-octets)
  (:import-from :flexi-streams)
  (:import-from :salza2)
  (:import-from :cl-oci/digest #:compute-digest #:format-digest)
  (:import-from :cl-oci/config #:+role-source+ #:+role-native-library+ #:+role-headers+
                #:+role-documentation+ #:+role-cffi-grovel-output+ #:+role-cffi-wrapper+
                #:+role-build-script+ #:+role-static-library+)
  (:export #:build-layer-from-directory
           #:build-layer-from-files
           #:layer-result
           #:layer-result-data
           #:layer-result-digest
           #:layer-result-size
           #:layer-result-role
           #:layer-result-title))
(in-package :cl-repository-packager/layer-builder)

(defclass layer-result ()
  ((data :type (vector (unsigned-byte 8)) :initarg :data :accessor layer-result-data)
   (digest :type string :initarg :digest :accessor layer-result-digest)
   (size :type integer :initarg :size :accessor layer-result-size)
   (role :type string :initarg :role :accessor layer-result-role)
   (title :type (or null string) :initarg :title :accessor layer-result-title :initform nil)))

(defparameter *excluded-dirs*
  '(".git" ".qlot" ".lake" "__pycache__" "node_modules")
  "Directory names to exclude from packaging.")

(defun excluded-dir-p (dir)
  "Return T if DIR's name matches an excluded directory."
  (let ((name (car (last (pathname-directory dir)))))
    (member name *excluded-dirs* :test #'string=)))

(defun collect-files (directory &key (strip-prefix directory))
  "Recursively collect files under DIRECTORY. Returns list of (relative-path . absolute-path)."
  (let ((files nil))
    (uiop:collect-sub*directories
     directory
     (lambda (d) (not (excluded-dir-p d)))
     (lambda (d) (not (excluded-dir-p d)))
     (lambda (subdir)
       (dolist (f (uiop:directory-files subdir))
         (let ((rel (enough-namestring f strip-prefix)))
           (push (cons rel f) files)))))
    (nreverse files)))

(defun make-tar-gzip-from-files (file-pairs &key tar-prefix)
  "Create a tar.gz archive from FILE-PAIRS ((relative-path . absolute-path) ...).
   When TAR-PREFIX is given (e.g. \"mylib-1.0/\"), prepend it to every entry name.
   Returns the archive as an octet vector."
  (let ((output (flexi-streams:make-in-memory-output-stream :element-type '(unsigned-byte 8))))
    (let ((gzip-stream (salza2:make-compressing-stream 'salza2:gzip-compressor output)))
      (dolist (pair file-pairs)
        (let* ((rel-path (car pair))
               (abs-path (cdr pair))
               (content (read-file-octets abs-path))
               (name (if tar-prefix
                         (concatenate 'string tar-prefix (namestring rel-path))
                         (namestring rel-path))))
          (write-tar-entry gzip-stream name content)))
      (write-tar-eof gzip-stream)
      (close gzip-stream))
    (let ((raw (flexi-streams:get-output-stream-sequence output)))
      (if (typep raw '(simple-array (unsigned-byte 8) (*)))
          raw
          (coerce raw '(simple-array (unsigned-byte 8) (*)))))))

(defun read-file-octets (path)
  "Read a file as an octet vector."
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8))))
      (read-sequence buf s)
      buf)))

(defun split-tar-name (name)
  "Split NAME into (prefix . name) for ustar format.
   Name field max 100 bytes, prefix field max 155 bytes.
   Split at the last / that keeps name <= 100 and prefix <= 155."
  (if (<= (length name) 100)
      (cons "" name)
      (let ((slash-pos nil))
        (loop for i from (min (length name) 155) downto 1
              when (char= (char name i) #\/)
                do (setf slash-pos i) (return))
        (if (and slash-pos (<= (- (length name) slash-pos 1) 100))
            (cons (subseq name 0 slash-pos) (subseq name (1+ slash-pos)))
            (cons "" (subseq name 0 100))))))

(defun write-tar-entry (stream name content)
  "Write a single tar entry (POSIX ustar header + data)."
  (let* ((split (split-tar-name name))
         (prefix-str (car split))
         (name-str (cdr split))
         (name-bytes (babel:string-to-octets name-str :encoding :utf-8))
         (prefix-bytes (babel:string-to-octets prefix-str :encoding :utf-8))
         (header (make-array 512 :element-type '(unsigned-byte 8) :initial-element 0))
         (size (length content)))
    ;; name field (0-99)
    (replace header name-bytes :end1 (min 100 (length name-bytes)))
    ;; mode field (100-107) - 0644
    (write-octal header 100 #o644 8)
    ;; uid/gid (108-123) - 0
    (write-octal header 108 0 8)
    (write-octal header 116 0 8)
    ;; size (124-135)
    (write-octal header 124 size 12)
    ;; mtime (136-147) - current time
    (write-octal header 136 (- (get-universal-time) 2208988800) 12)
    ;; typeflag (156) - '0' regular file
    (setf (aref header 156) (char-code #\0))
    ;; magic (257-262) "ustar\0" + version "00"
    (let ((magic (babel:string-to-octets "ustar" :encoding :ascii)))
      (replace header magic :start1 257))
    (setf (aref header 263) (char-code #\0))
    (setf (aref header 264) (char-code #\0))
    ;; prefix field (345-499)
    (when (plusp (length prefix-bytes))
      (replace header prefix-bytes :start1 345 :end1 (min 500 (+ 345 (length prefix-bytes)))))
    ;; Compute checksum (field bytes treated as spaces per POSIX)
    (fill header (char-code #\Space) :start 148 :end 156)
    (let ((sum (reduce #'+ header)))
      (write-octal header 148 sum 7))
    ;; Write header
    (write-sequence header stream)
    ;; Write content
    (write-sequence content stream)
    ;; Pad to 512-byte boundary
    (let ((remainder (mod size 512)))
      (when (plusp remainder)
        (write-sequence (make-array (- 512 remainder)
                                    :element-type '(unsigned-byte 8)
                                    :initial-element 0)
                        stream)))))

(defun write-tar-eof (stream)
  "Write two 512-byte zero blocks to mark end of tar archive."
  (let ((zeros (make-array 1024 :element-type '(unsigned-byte 8) :initial-element 0)))
    (write-sequence zeros stream)))

(defun write-octal (buf offset value width)
  "Write VALUE as octal ASCII string into BUF at OFFSET with WIDTH characters."
  (let ((str (format nil "~v,'0o" (1- width) value)))
    (loop for i from 0 below (min (length str) (1- width))
          do (setf (aref buf (+ offset i)) (char-code (char str i))))
    (setf (aref buf (+ offset (1- width))) 0)))

(defun build-layer-from-directory (directory role &key (strip-prefix directory) tar-prefix)
  "Build a tar+gzip layer from all files in DIRECTORY.
   TAR-PREFIX: when given, prepend to every entry name (e.g. \"mylib-1.0/\").
   Returns a LAYER-RESULT."
  (let* ((files (collect-files (truename directory) :strip-prefix (truename strip-prefix)))
         (data (make-tar-gzip-from-files files :tar-prefix tar-prefix))
         (digest-obj (compute-digest data)))
    (make-instance 'layer-result
                   :data data
                   :digest (format-digest digest-obj)
                   :size (length data)
                   :role role)))

(defun build-layer-from-files (file-pairs role)
  "Build a tar+gzip layer from explicit FILE-PAIRS. Returns a LAYER-RESULT."
  (let* ((data (make-tar-gzip-from-files file-pairs))
         (digest-obj (compute-digest data)))
    (make-instance 'layer-result
                   :data data
                   :digest (format-digest digest-obj)
                   :size (length data)
                   :role role)))
