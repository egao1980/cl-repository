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

(deftest issue-193-an-implication-keeps-its-predicate-and-its-parts
  "cl-repository#193: SAT-IMPLY had the slots P and Q, so SAT-IMPLY-P named
   both the structure's predicate and the accessor of P. SBCL kept the
   accessor and warned. An implementation that keeps the predicate would make
   every antecedent T, and every implication of the dependency constraints
   wrong without an error. SAT-IMPLY-P is the predicate, and each walk over
   an implication (free variables, replacement, evaluation) reaches both
   sides."
  (let* ((expr (sat-imply (sat-var "a") (sat-var "b")))
         (got (cl-repository-client/solver::sat-imply-p expr)))
    (ok (and got (not (typep got 'structure-object)))
        (format nil "SAT-IMPLY-P is the structure predicate, not a slot accessor (got ~s)" got))
    (ok (not (cl-repository-client/solver::sat-imply-p (sat-var "a")))
        "and is false for another expression")
    (ok (equal (sat-free-vars expr) '("a" "b")) "both sides' variables are free")
    (ok (equal (sat-free-vars (sat-replace expr "b" nil)) '("a"))
        "a replaced consequent keeps the antecedent")
    (ok (sat-eval (sat-replace (sat-replace expr "a" nil) "b" nil))
        "a false antecedent makes the implication true")
    (ok (not (sat-eval (sat-replace (sat-replace expr "a" t) "b" nil)))
        "a true antecedent and a false consequent make it false")))

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

(deftest test-solve-prefers-semantic-latest-version
  ;; 1.10 > 1.9 semantically, though "1.10" < "1.9" as strings
  (let ((formula (sat-and (list (sat-or (list (sat-var "foo-v1.9") (sat-var "foo-v1.10")))
                                (sat-not (sat-and (list (sat-var "foo-v1.9")
                                                        (sat-var "foo-v1.10"))))))))
    (let ((bindings (sat-solve formula)))
      (ok bindings)
      (ok (cdr (assoc "foo-v1.10" bindings :test #'string=)))
      (ok (not (cdr (assoc "foo-v1.9" bindings :test #'string=)))))))

(deftest test-replace-folds-constants
  ;; After substitution the formula should shrink, not keep constant leaves
  (let* ((expr (sat-and (list (sat-var "x") (sat-or (list (sat-var "x") (sat-var "y"))))))
         (folded (sat-replace expr "x" t)))
    (ok (typep folded 'sat-true))))

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
