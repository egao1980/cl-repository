(defpackage :cl-repository-client/solver
  (:use :cl)
  (:import-from :cl-repository-client/version-utils #:version<)
  (:export #:sat-true #:sat-false #:sat-var #:sat-not #:sat-and #:sat-or #:sat-imply
           #:sat-var-name
           #:sat-eval #:sat-free-vars #:sat-replace #:sat-solve))
(in-package :cl-repository-client/solver)

;;; Expr types -- defstruct for lightweight, fast matching

(defstruct (sat-true (:constructor sat-true)))
(defstruct (sat-false (:constructor sat-false)))
(defstruct (sat-var (:constructor sat-var (name))) (name "" :type string))
(defstruct (sat-not (:constructor sat-not (expr))) expr)
(defstruct (sat-and (:constructor sat-and (exprs))) (exprs nil :type list))
(defstruct (sat-or (:constructor sat-or (exprs))) (exprs nil :type list))
(defstruct (sat-imply (:constructor sat-imply (p q))) p q)

;;; Evaluation (ground expressions only)

(defun sat-eval (expr)
  "Evaluate a ground (variable-free) expression. Returns T or NIL."
  (etypecase expr
    (sat-true t)
    (sat-false nil)
    (sat-var (error "Cannot evaluate unbound variable: ~a" (sat-var-name expr)))
    (sat-not (not (sat-eval (sat-not-expr expr))))
    (sat-and (every #'sat-eval (sat-and-exprs expr)))
    (sat-or (some #'sat-eval (sat-or-exprs expr)))
    (sat-imply (or (not (sat-eval (sat-imply-p expr)))
                   (sat-eval (sat-imply-q expr))))))

;;; Free variable extraction

(defun sat-free-vars (expr)
  "Return a sorted, deduplicated list of variable name strings."
  (let ((vars (make-hash-table :test 'equal)))
    (collect-vars expr vars)
    (sort (loop for k being the hash-keys of vars collect k) #'string<)))

(defun collect-vars (expr table)
  (etypecase expr
    ((or sat-true sat-false) nil)
    (sat-var (setf (gethash (sat-var-name expr) table) t))
    (sat-not (collect-vars (sat-not-expr expr) table))
    (sat-and (dolist (e (sat-and-exprs expr)) (collect-vars e table)))
    (sat-or (dolist (e (sat-or-exprs expr)) (collect-vars e table)))
    (sat-imply (collect-vars (sat-imply-p expr) table)
               (collect-vars (sat-imply-q expr) table))))

;;; Simplifying constructors (constant folding)
;;;
;;; Substitution uses these so formulas shrink as variables get bound; the
;;; naive rebuild kept the full tree and made backtracking exponential in
;;; formula size rather than in the number of *remaining* variables.

(defun fold-not (expr)
  (typecase expr
    (sat-true (sat-false))
    (sat-false (sat-true))
    (t (sat-not expr))))

(defun fold-and (exprs)
  (let ((kept nil))
    (dolist (e exprs)
      (typecase e
        (sat-false (return-from fold-and (sat-false)))
        (sat-true)                      ; identity, drop
        (t (push e kept))))
    (cond ((null kept) (sat-true))
          ((null (cdr kept)) (car kept))
          (t (sat-and (nreverse kept))))))

(defun fold-or (exprs)
  (let ((kept nil))
    (dolist (e exprs)
      (typecase e
        (sat-true (return-from fold-or (sat-true)))
        (sat-false)                     ; identity, drop
        (t (push e kept))))
    (cond ((null kept) (sat-false))
          ((null (cdr kept)) (car kept))
          (t (sat-or (nreverse kept))))))

(defun fold-imply (p q)
  (typecase p
    (sat-false (sat-true))
    (sat-true q)
    (t (typecase q
         (sat-true (sat-true))
         (t (sat-imply p q))))))

;;; Variable replacement

(defun sat-replace (expr var-name value)
  "Replace all occurrences of VAR-NAME with VALUE (T/NIL) in EXPR.
   Folds constants while rebuilding, so the result is simplified."
  (etypecase expr
    (sat-true expr)
    (sat-false expr)
    (sat-var (if (string= (sat-var-name expr) var-name)
                 (if value (sat-true) (sat-false))
                 expr))
    (sat-not (fold-not (sat-replace (sat-not-expr expr) var-name value)))
    (sat-and (fold-and (mapcar (lambda (e) (sat-replace e var-name value))
                               (sat-and-exprs expr))))
    (sat-or (fold-or (mapcar (lambda (e) (sat-replace e var-name value))
                             (sat-or-exprs expr))))
    (sat-imply (fold-imply (sat-replace (sat-imply-p expr) var-name value)
                           (sat-replace (sat-imply-q expr) var-name value)))))

;;; Solver with latest-version heuristic

(defun split-pkg-var (var-name)
  "Split a \"name-vVERSION\" variable into (values name version).
   VERSION is NIL when the variable doesn't follow the pkg-var convention."
  (let ((pos (search "-v" var-name :from-end t)))
    (if pos
        (values (subseq var-name 0 pos) (subseq var-name (+ pos 2)))
        (values var-name nil))))

(defun var-precedes-p (a b)
  "Order variables by package name, then by semantic version.
   Ensures the solver prefers 1.10 over 1.9 (plain string order would not)."
  (multiple-value-bind (name-a ver-a) (split-pkg-var a)
    (multiple-value-bind (name-b ver-b) (split-pkg-var b)
      (cond
        ((string< name-a name-b) t)
        ((string> name-a name-b) nil)
        ((and ver-a ver-b) (version< ver-a ver-b))
        (t (string< a b))))))

(defun sat-solve (expr &optional (bindings nil))
  "Solve EXPR. Returns bindings alist ((name . T/NIL) ...) or NIL if unsatisfiable.
   Heuristic: picks the version-wise highest variable and tries T first,
   so the latest version of each package is preferred."
  (let ((vars (sat-free-vars expr)))
    (if (null vars)
        (when (sat-eval expr) bindings)
        (let ((var (reduce (lambda (a b) (if (var-precedes-p a b) b a)) vars)))
          ;; Try T first (prefer installing a version over not)
          (or (sat-solve (sat-replace expr var t)
                         (acons var t bindings))
              (sat-solve (sat-replace expr var nil)
                         (acons var nil bindings)))))))
