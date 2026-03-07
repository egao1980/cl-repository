(defpackage :cl-repository-ql-exporter/tests/repackager-test
  (:use :cl :rove)
  (:import-from :cl-repository-ql-exporter/repackager
                #:repackage-project #:repackage-result
                #:repackage-result-index-json #:repackage-result-index-digest
                #:repackage-result-manifest-json #:repackage-result-manifest-digest
                #:repackage-result-blobs)
  (:import-from :cl-repository-ql-exporter/dist-parser
                #:ql-release #:ql-system))
(in-package :cl-repository-ql-exporter/tests/repackager-test)

(defun make-test-release ()
  (make-instance 'ql-release
                 :project "test-project"
                 :url "http://example.com/test.tgz"
                 :size 100
                 :file-md5 "abc"
                 :content-sha1 "def"
                 :prefix "test-20260101"
                 :system-files '("test.asd")))

(defun make-test-systems ()
  (list (make-instance 'ql-system
                       :project "test-project"
                       :system-file "test.asd"
                       :system-name "test-system"
                       :dependencies '("alexandria"))))

(deftest repackage-project-test
  (let* ((fake-tar-gz (make-array 64 :element-type '(unsigned-byte 8) :initial-element 42))
         (result (repackage-project fake-tar-gz
                                    (make-test-release)
                                    (make-test-systems)
                                    :version "1.0")))
    (ok (stringp (repackage-result-index-json result)))
    (ok (search "sha256:" (repackage-result-index-digest result)))
    (ok (stringp (repackage-result-manifest-json result)))
    (ok (search "sha256:" (repackage-result-manifest-digest result)))
    ;; Should have 2 blobs: source layer + config
    (ok (= (length (repackage-result-blobs result)) 2))))
