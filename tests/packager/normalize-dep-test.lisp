(defpackage :cl-repository-packager/tests/normalize-dep-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/asdf-plugin #:normalize-dep))
(in-package :cl-repository-packager/tests/normalize-dep-test)

(deftest test-normalize-string
  (ok (string= (normalize-dep "alexandria") "alexandria")))

(deftest test-normalize-string-uppercase
  (ok (string= (normalize-dep "ALEXANDRIA") "alexandria")))

(deftest test-normalize-symbol
  (ok (string= (normalize-dep :cffi) "cffi")))

(deftest test-normalize-versioned
  (let ((result (normalize-dep '(:version "babel" "0.5"))))
    (ok (consp result))
    (ok (string= (car result) "babel"))
    (ok (string= (cdr result) "0.5"))))

(deftest test-normalize-versioned-symbol
  (let ((result (normalize-dep '(:version :babel "0.5"))))
    (ok (consp result))
    (ok (string= (car result) "babel"))
    (ok (string= (cdr result) "0.5"))))

(deftest test-normalize-feature-simple
  (ok (string= (normalize-dep '(:feature :win32 "winhttp")) "winhttp")))

(deftest test-normalize-feature-or-expression
  (ok (string= (normalize-dep '(:feature (:or :win32 :windows :mswindows) "winhttp"))
               "winhttp")))

(deftest test-normalize-require-dropped
  (ok (null (normalize-dep '(:require :sb-posix)))))
