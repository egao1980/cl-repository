(defpackage :cl-repository-client/tests/digest-cache-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/digest-cache
                #:*installed-digests* #:digest-already-installed-p
                #:record-installed-digest))
(in-package :cl-repository-client/tests/digest-cache-test)

(deftest test-digest-cache-basic
  (let ((*installed-digests* (make-hash-table :test 'equal)))
    (ok (null (digest-already-installed-p "sha256:abc123")))
    (record-installed-digest "sha256:abc123" #P"/tmp/test/")
    (ok (string= (digest-already-installed-p "sha256:abc123") "/tmp/test/"))
    (ok (null (digest-already-installed-p "sha256:other")))))

(deftest test-digest-cache-multiple
  (let ((*installed-digests* (make-hash-table :test 'equal)))
    (record-installed-digest "sha256:aaa" #P"/path/a/")
    (record-installed-digest "sha256:bbb" #P"/path/b/")
    (ok (string= (digest-already-installed-p "sha256:aaa") "/path/a/"))
    (ok (string= (digest-already-installed-p "sha256:bbb") "/path/b/"))))
