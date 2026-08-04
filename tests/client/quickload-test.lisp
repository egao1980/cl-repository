(defpackage :cl-repository-client/tests/quickload-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/quickload
                #:asdf-dep-name
                #:system-direct-deps
                #:collect-missing-asdf-deps))
(in-package :cl-repository-client/tests/quickload-test)

(deftest test-asdf-dep-name-string
  (ok (string= "alexandria" (asdf-dep-name "Alexandria")))
  (ok (string= "alexandria" (asdf-dep-name 'alexandria))))

(deftest test-asdf-dep-name-version
  (ok (string= "foo" (asdf-dep-name '(:version "foo" "1.0")))))

(deftest test-asdf-dep-name-feature
  (ok (string= "uiop" (asdf-dep-name (list :feature (first *features*) "uiop"))))
  (ok (null (asdf-dep-name (list :feature (gensym) "nope")))))

(deftest test-asdf-dep-name-require
  (ok (null (asdf-dep-name '(:require "sb-posix")))))

(deftest test-system-direct-deps-findable
  (let ((deps (system-direct-deps "asdf")))
    (ok (listp deps))))

(deftest test-collect-missing-skips-local-root
  ;; asdf is always findable; collecting from it should not list "asdf" itself.
  (let ((missing (collect-missing-asdf-deps '("asdf"))))
    (ok (not (member "asdf" missing :test #'string=)))))
