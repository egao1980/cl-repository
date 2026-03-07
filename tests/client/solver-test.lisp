(defpackage :cl-repository-client/tests/solver-test
  (:use :cl :rove)
  (:import-from :cl-repository-client/solver
                #:sat-true #:sat-false #:sat-var #:sat-not #:sat-and #:sat-or #:sat-imply
                #:sat-var-name #:sat-eval #:sat-free-vars #:sat-replace #:sat-solve))
(in-package :cl-repository-client/tests/solver-test)

;;; sat-eval

(deftest test-eval-constants
  (ok (sat-eval (sat-true)))
  (ok (not (sat-eval (sat-false)))))

(deftest test-eval-not
  (ok (not (sat-eval (sat-not (sat-true)))))
  (ok (sat-eval (sat-not (sat-false)))))

(deftest test-eval-and
  (ok (sat-eval (sat-and (list (sat-true) (sat-true)))))
  (ok (not (sat-eval (sat-and (list (sat-true) (sat-false))))))
  (ok (not (sat-eval (sat-and (list (sat-false) (sat-false)))))))

(deftest test-eval-or
  (ok (sat-eval (sat-or (list (sat-true) (sat-false)))))
  (ok (sat-eval (sat-or (list (sat-false) (sat-true)))))
  (ok (not (sat-eval (sat-or (list (sat-false) (sat-false)))))))

(deftest test-eval-imply
  (ok (sat-eval (sat-imply (sat-false) (sat-false))))
  (ok (sat-eval (sat-imply (sat-false) (sat-true))))
  (ok (not (sat-eval (sat-imply (sat-true) (sat-false)))))
  (ok (sat-eval (sat-imply (sat-true) (sat-true)))))

;;; sat-free-vars

(deftest test-free-vars
  (let ((vars (sat-free-vars (sat-and (list (sat-var "a") (sat-var "b") (sat-var "a"))))))
    (ok (equal vars '("a" "b")))))

(deftest test-free-vars-empty
  (ok (null (sat-free-vars (sat-true)))))

;;; sat-replace

(deftest test-replace
  (let ((expr (sat-and (list (sat-var "x") (sat-var "y")))))
    (let ((replaced (sat-replace expr "x" t)))
      (ok (equal (sat-free-vars replaced) '("y"))))))

;;; sat-solve

(deftest test-solve-trivial
  (let ((bindings (sat-solve (sat-var "a"))))
    (ok bindings)
    (ok (cdr (assoc "a" bindings :test #'string=)))))

(deftest test-solve-unsatisfiable
  ;; a AND (NOT a) is unsatisfiable
  (ok (null (sat-solve (sat-and (list (sat-var "a") (sat-not (sat-var "a"))))))))

(deftest test-solve-mutual-exclusion
  ;; a OR b, but NOT (a AND b)
  (let ((formula (sat-and (list (sat-or (list (sat-var "a") (sat-var "b")))
                                (sat-not (sat-and (list (sat-var "a") (sat-var "b"))))))))
    (let ((bindings (sat-solve formula)))
      (ok bindings)
      (let ((a (cdr (assoc "a" bindings :test #'string=)))
            (b (cdr (assoc "b" bindings :test #'string=))))
        ;; Exactly one should be true
        (ok (not (and a b)))
        (ok (or a b))))))

(deftest test-solve-latest-version-heuristic
  ;; Must pick exactly one of foo-v1 or foo-v2, solver should prefer foo-v2 (latest)
  (let ((formula (sat-and (list (sat-or (list (sat-var "foo-v1") (sat-var "foo-v2")))
                                (sat-not (sat-and (list (sat-var "foo-v1") (sat-var "foo-v2"))))))))
    (let ((bindings (sat-solve formula)))
      (ok bindings)
      (ok (cdr (assoc "foo-v2" bindings :test #'string=)))
      (ok (not (cdr (assoc "foo-v1" bindings :test #'string=)))))))

(deftest test-solve-dependency-chain
  ;; app-v1 requires lib-v1 OR lib-v2
  ;; lib-v2 requires util-v1
  ;; mutual exclusion for lib
  (let ((formula (sat-and (list (sat-var "app-v1")
                                (sat-imply (sat-var "app-v1")
                                           (sat-or (list (sat-var "lib-v1") (sat-var "lib-v2"))))
                                (sat-imply (sat-var "lib-v2") (sat-var "util-v1"))
                                (sat-not (sat-and (list (sat-var "lib-v1") (sat-var "lib-v2"))))))))
    (let ((bindings (sat-solve formula)))
      (ok bindings)
      (ok (cdr (assoc "app-v1" bindings :test #'string=)))
      ;; Should pick lib-v2 (latest) and util-v1
      (ok (cdr (assoc "lib-v2" bindings :test #'string=)))
      (ok (cdr (assoc "util-v1" bindings :test #'string=))))))

(deftest test-solve-diamond-deps
  ;; app requires A and B
  ;; A requires D@v1 or D@v2
  ;; B requires D@v2 only
  ;; So D must be v2
  (let ((formula (sat-and (list (sat-var "app-v1")
                                (sat-imply (sat-var "app-v1") (sat-var "a-v1"))
                                (sat-imply (sat-var "app-v1") (sat-var "b-v1"))
                                (sat-imply (sat-var "a-v1")
                                           (sat-or (list (sat-var "d-v1") (sat-var "d-v2"))))
                                (sat-imply (sat-var "b-v1") (sat-var "d-v2"))
                                (sat-not (sat-and (list (sat-var "d-v1") (sat-var "d-v2"))))))))
    (let ((bindings (sat-solve formula)))
      (ok bindings)
      (ok (cdr (assoc "d-v2" bindings :test #'string=)))
      (ok (not (cdr (assoc "d-v1" bindings :test #'string=)))))))
