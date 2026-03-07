(defpackage :cl-repository-client/solver
  (:use :cl)
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

;;; Variable replacement

(defun sat-replace (expr var-name value)
  "Replace all occurrences of VAR-NAME with VALUE (T/NIL) in EXPR."
  (etypecase expr
    (sat-true expr)
    (sat-false expr)
    (sat-var (if (string= (sat-var-name expr) var-name)
                 (if value (sat-true) (sat-false))
                 expr))
    (sat-not (sat-not (sat-replace (sat-not-expr expr) var-name value)))
    (sat-and (sat-and (mapcar (lambda (e) (sat-replace e var-name value))
                              (sat-and-exprs expr))))
    (sat-or (sat-or (mapcar (lambda (e) (sat-replace e var-name value))
                            (sat-or-exprs expr))))
    (sat-imply (sat-imply (sat-replace (sat-imply-p expr) var-name value)
                          (sat-replace (sat-imply-q expr) var-name value)))))

;;; Solver with latest-version heuristic

(defun sat-solve (expr &optional (bindings nil))
  "Solve EXPR. Returns bindings alist ((name . T/NIL) ...) or NIL if unsatisfiable.
   Heuristic: picks the last variable alphabetically (highest version) and tries T first."
  (let ((vars (sat-free-vars expr)))
    (if (null vars)
        (when (sat-eval expr) bindings)
        ;; Pick last var (latest version due to alphabetical sort of pkg-vN.N.N)
        (let ((var (car (last vars))))
          ;; Try T first (prefer installing a version over not)
          (or (sat-solve (sat-replace expr var t)
                         (acons var t bindings))
              (sat-solve (sat-replace expr var nil)
                         (acons var nil bindings)))))))
