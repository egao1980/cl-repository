(defpackage :cl-repository-packager/tests/layer-builder-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/layer-builder
                #:build-layer-from-directory #:layer-result
                #:layer-result-data #:layer-result-digest #:layer-result-size
                #:layer-result-role #:layer-result-title #:make-tar-gzip-from-files)
  (:import-from :chipz)
  (:import-from :flexi-streams)
  (:import-from :babel #:string-to-octets #:octets-to-string))
(in-package :cl-repository-packager/tests/layer-builder-test)

(defun tar-entry-names (tar-gz-data)
  "Extract file names from a tar.gz archive."
  (let ((input (flexi-streams:make-in-memory-input-stream tar-gz-data))
        (names nil))
    (let ((decomp (chipz:make-decompressing-stream 'chipz:gzip input)))
      (loop
        (let ((header (make-array 512 :element-type '(unsigned-byte 8))))
          (let ((n (read-sequence header decomp)))
            (when (or (< n 512) (every #'zerop header))
              (return)))
          (let* ((end (or (position 0 header :end 100) 100))
                 (name (babel:octets-to-string (subseq header 0 end) :encoding :utf-8))
                 (prefix-end (or (position 0 header :start 345 :end 500) 500))
                 (prefix (babel:octets-to-string (subseq header 345 prefix-end) :encoding :utf-8))
                 (full-name (if (plusp (length prefix))
                                (concatenate 'string prefix "/" name)
                                name))
                 (size-str (babel:octets-to-string (subseq header 124 136) :encoding :ascii))
                 (trimmed (string-trim '(#\Space #\Null) size-str))
                 (size (if (zerop (length trimmed)) 0 (parse-integer trimmed :radix 8)))
                 (blocks (ceiling size 512)))
            (push full-name names)
            (dotimes (i blocks)
              (let ((buf (make-array 512 :element-type '(unsigned-byte 8))))
                (read-sequence buf decomp))))))
      (close decomp))
    (nreverse names)))

(deftest tar-prefix-prepended
  (testing "make-tar-gzip-from-files with :tar-prefix prepends to entry names"
    (let* ((tmpdir (uiop:ensure-directory-pathname
                    (format nil "/tmp/cl-repo-lb-test-~a/" (get-universal-time))))
           (file1 (merge-pathnames "hello.lisp" tmpdir)))
      (unwind-protect
           (progn
             (ensure-directories-exist file1)
             (with-open-file (s file1 :direction :output :if-exists :supersede)
               (write-string "(defun hello () t)" s))
             (let* ((pairs (list (cons "hello.lisp" file1)))
                    (data (make-tar-gzip-from-files pairs :tar-prefix "mylib-1.0/"))
                    (names (tar-entry-names data)))
               (ok (member "mylib-1.0/hello.lisp" names :test #'string=)
                   "entry should have tar-prefix prepended")))
        (when (probe-file file1) (delete-file file1))
        (uiop:delete-directory-tree tmpdir :validate t :if-does-not-exist :ignore)))))

(deftest tar-no-prefix-default
  (testing "make-tar-gzip-from-files without :tar-prefix uses bare names"
    (let* ((tmpdir (uiop:ensure-directory-pathname
                    (format nil "/tmp/cl-repo-lb-test2-~a/" (get-universal-time))))
           (file1 (merge-pathnames "foo.lisp" tmpdir)))
      (unwind-protect
           (progn
             (ensure-directories-exist file1)
             (with-open-file (s file1 :direction :output :if-exists :supersede)
               (write-string "(defun foo () nil)" s))
             (let* ((pairs (list (cons "foo.lisp" file1)))
                    (data (make-tar-gzip-from-files pairs))
                    (names (tar-entry-names data)))
               (ok (member "foo.lisp" names :test #'string=)
                   "entry should have bare name")))
        (when (probe-file file1) (delete-file file1))
        (uiop:delete-directory-tree tmpdir :validate t :if-does-not-exist :ignore)))))

(deftest layer-result-title-slot
  (testing "layer-result has an optional title slot"
    (let ((lr (make-instance 'layer-result
                             :data (make-array 0 :element-type '(unsigned-byte 8))
                             :digest "sha256:abc"
                             :size 0
                             :role "source")))
      (ok (null (layer-result-title lr)) "title defaults to nil")
      (setf (layer-result-title lr) "mylib-1.0.tar.gz")
      (ok (string= (layer-result-title lr) "mylib-1.0.tar.gz")))))
