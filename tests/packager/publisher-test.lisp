(defpackage :cl-repository-packager/tests/publisher-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/publisher #:system-name-anchor-targets)
  (:import-from :cl-repository-packager/build-matrix #:package-spec))
(in-package :cl-repository-packager/tests/publisher-test)

(deftest system-name-anchor-targets-skips-slash
  (let ((spec (make-instance 'package-spec
                             :name "rove"
                             :provides '("rove" "rove/main" "rove/core/assertion"))))
    (ok (equal (system-name-anchor-targets "egao1980/cl-systems" spec)
               '("egao1980/cl-systems/rove")))))

(deftest system-name-anchor-targets-encodes-plus
  (let ((spec (make-instance 'package-spec
                             :name "cl+ssl"
                             :provides '("cl+ssl"))))
    (ok (equal (system-name-anchor-targets "egao1980/cl-systems" spec)
               '("egao1980/cl-systems/cl-plus-ssl")))))

(deftest system-name-anchor-targets-falls-back-to-name
  (let ((spec (make-instance 'package-spec :name "alexandria" :provides nil)))
    (ok (equal (system-name-anchor-targets "egao1980/cl-systems" spec)
               '("egao1980/cl-systems/alexandria")))))
