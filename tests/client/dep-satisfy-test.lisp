(defpackage :cl-repository-client/tests/dep-satisfy-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/dep-satisfy
                #:version-satisfies-p
                #:quicklisp-source-p
                #:system-satisfied-p))
(in-package :cl-repository-client/tests/dep-satisfy-test)

(deftest version-satisfies-p-table
  (dolist (row '(("0.3.9" "0.3.9" t)
                 ("0.3.2" "0.3.9" nil)
                 ("1.0.0" "0.3.9" t)
                 ("0.3.9" "1.0.0" nil)
                 ("0.3.10" "0.3.9" t)
                 ("1.0.0" "1.0" t)
                 ("1.0" "1.0.0" nil)
                 ("1.2.3b" "1.2.3a" t)
                 ("1.2.3a" "1.2.3b" nil)
                 ("1.2.3" "1.2.3a" nil)
                 ("1.2.3a" "1.2.3" t)
                 ("1.2.3-rc2" "1.2.3-rc1" t)
                 ("1.2.4-alpha" "1.2.3" t)
                 ("0.9.0zzz" "1.0.0" nil)))
    (let ((have (first row))
          (need (second row))
          (expected (third row)))
      (ok (eq expected (version-satisfies-p have need))
          (format nil "~S satisfies ~S is ~S" have need expected)))))

(deftest version-satisfies-p-nil
  (ok (eq t (version-satisfies-p "1.2.3" nil)))
  (ok (eq t (version-satisfies-p nil nil)))
  (ok (eq nil (version-satisfies-p nil "1.2.3"))))

(deftest quicklisp-source-p-missing-system
  (ok (eq nil (quicklisp-source-p "no-such-system-cl-repo-dep-satisfy")))
  (ok (eq nil (quicklisp-source-p :no-such-system-cl-repo-dep-satisfy))))

(deftest system-satisfied-p-missing-system
  (ok (eq nil (system-satisfied-p "no-such-system-cl-repo-dep-satisfy")))
  (ok (eq nil (system-satisfied-p "no-such-system-cl-repo-dep-satisfy" :version "1.0.0"))))
