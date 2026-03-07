(defpackage :cl-repository-ql-exporter/tests/dist-parser-test
  (:use :cl :rove)
  (:import-from :cl-repository-ql-exporter/dist-parser
                #:parse-distinfo #:parse-releases #:parse-systems
                #:ql-dist-name #:ql-dist-version #:ql-dist-archive-base-url
                #:ql-release-project #:ql-release-url #:ql-release-prefix
                #:ql-system-project #:ql-system-system-name #:ql-system-dependencies))
(in-package :cl-repository-ql-exporter/tests/dist-parser-test)

(defvar *test-distinfo*
  "name: quicklisp
version: 2026-01-01
system-index-url: http://example.com/systems.txt
release-index-url: http://example.com/releases.txt
archive-base-url: http://example.com/")

(defvar *test-releases*
  "# header
alexandria http://example.com/alexandria.tgz 52345 abc123 def456 alexandria-20260101-git alexandria.asd
cffi http://example.com/cffi.tgz 123456 aaa111 bbb222 cffi-20260101-git cffi.asd cffi-toolchain.asd")

(defvar *test-systems*
  "# header
alexandria alexandria.asd alexandria
cffi cffi.asd cffi alexandria babel trivial-features
cffi cffi-toolchain.asd cffi-toolchain cffi")

(deftest parse-distinfo-test
  (let ((dist (parse-distinfo *test-distinfo*)))
    (ok (string= (ql-dist-name dist) "quicklisp"))
    (ok (string= (ql-dist-version dist) "2026-01-01"))
    (ok (string= (ql-dist-archive-base-url dist) "http://example.com/"))))

(deftest parse-releases-test
  (let ((releases (parse-releases *test-releases*)))
    (ok (= (length releases) 2))
    (ok (string= (ql-release-project (first releases)) "alexandria"))
    (ok (string= (ql-release-prefix (first releases)) "alexandria-20260101-git"))
    (ok (string= (ql-release-project (second releases)) "cffi"))))

(deftest parse-systems-test
  (let ((systems (parse-systems *test-systems*)))
    (ok (= (length systems) 3))
    (ok (string= (ql-system-project (first systems)) "alexandria"))
    (ok (string= (ql-system-system-name (second systems)) "cffi"))
    (ok (= (length (ql-system-dependencies (second systems))) 3))
    (ok (string= (first (ql-system-dependencies (second systems))) "alexandria"))))
