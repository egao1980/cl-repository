(defpackage :cl-repository-packager/tests/publisher-test
  (:use :cl :rove)
  (:import-from :cl-repository-packager/publisher
                #:system-name-anchor-targets #:anchor-should-move-p)
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

(deftest anchor-should-move-p-keeps-newer-latest
  (ok (not (anchor-should-move-p "0.2.1" "0.2.0")))
  (ok (not (anchor-should-move-p "1.0.0" "0.9.9"))))

(deftest anchor-should-move-p-moves-forward-or-same
  (ok (anchor-should-move-p "0.2.0" "0.2.1"))
  (ok (anchor-should-move-p "0.2.1" "0.2.1"))
  (ok (anchor-should-move-p "0.2" "0.10")))

(deftest anchor-should-move-p-unknown-moves
  (ok (anchor-should-move-p nil "0.2.0"))
  (ok (anchor-should-move-p "main" "0.2.0"))
  (ok (anchor-should-move-p "0.2.1" "snapshot")))
