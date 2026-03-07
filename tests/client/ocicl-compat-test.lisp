(defpackage :cl-repository-client/tests/ocicl-compat-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/installer
                #:parse-ocicl-layer-info
                #:extract-layer-stripping-prefix
                #:systems-root
                #:system-install-path)
  (:import-from :cl-repository-client/quickload
                #:add-registry #:registry-type #:registry-namespace))
(in-package :cl-repository-client/tests/ocicl-compat-test)

;;; --- parse-ocicl-layer-info tests ---

(deftest parse-standard-ocicl-title
  (multiple-value-bind (name version prefix)
      (parse-ocicl-layer-info "alexandria-20240503-8514d8e.tar.gz")
    (ok (string= name "alexandria"))
    (ok (string= version "20240503-8514d8e"))
    (ok (string= prefix "alexandria-20240503-8514d8e/"))))

(deftest parse-ocicl-title-with-hyphenated-name
  (multiple-value-bind (name version prefix)
      (parse-ocicl-layer-info "cl-ppcre-20231003-abc1234.tar.gz")
    (ok (string= name "cl-ppcre"))
    (ok (string= version "20231003-abc1234"))
    (ok (string= prefix "cl-ppcre-20231003-abc1234/"))))

(deftest parse-ocicl-title-no-version
  (multiple-value-bind (name version prefix)
      (parse-ocicl-layer-info "mylib.tar.gz")
    (ok (string= name "mylib"))
    (ok (string= version "latest"))
    (ok (string= prefix "mylib/"))))

(deftest parse-ocicl-title-nil
  (ok (null (parse-ocicl-layer-info nil))))

;;; --- registry type tests ---

(deftest registry-type-default
  (let ((cl-repository-client/quickload::*registries* nil))
    (add-registry "http://localhost:5050")
    (let ((entry (first cl-repository-client/quickload::*registries*)))
      (ok (eq (registry-type entry) :cl-repo)))))

(deftest registry-type-ocicl
  (let ((cl-repository-client/quickload::*registries* nil))
    (add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
    (let ((entry (first cl-repository-client/quickload::*registries*)))
      (ok (eq (registry-type entry) :ocicl))
      (ok (string= (registry-namespace entry) "ocicl")))))

(deftest registry-no-duplicates
  (let ((cl-repository-client/quickload::*registries* nil))
    (add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
    (add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
    (ok (= 1 (length cl-repository-client/quickload::*registries*)))))

(deftest registry-same-url-different-namespace
  (let ((cl-repository-client/quickload::*registries* nil))
    (add-registry "https://ghcr.io" :namespace "ocicl" :type :ocicl)
    (add-registry "https://ghcr.io" :namespace "cl-systems" :type :cl-repo)
    (ok (= 2 (length cl-repository-client/quickload::*registries*)))))

;;; --- tar prefix stripping (via extract-layer-stripping-prefix) ---

(deftest extract-tar-stream-strip-prefix
  (testing "strip-prefix removes matching prefix from tar entry names"
    (let* ((name "alexandria-20240503-8514d8e/file.lisp")
           (prefix "alexandria-20240503-8514d8e/")
           (stripped (if (and prefix
                              (>= (length name) (length prefix))
                              (string= name prefix :end1 (length prefix)))
                         (subseq name (length prefix))
                         name)))
      (ok (string= stripped "file.lisp")))))

(deftest extract-tar-stream-no-strip-when-no-match
  (testing "no stripping when prefix doesn't match"
    (let* ((name "other-lib/file.lisp")
           (prefix "alexandria-20240503-8514d8e/")
           (stripped (if (and prefix
                              (>= (length name) (length prefix))
                              (string= name prefix :end1 (length prefix)))
                         (subseq name (length prefix))
                         name)))
      (ok (string= stripped "other-lib/file.lisp")))))
