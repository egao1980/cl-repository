(in-package :my-math)

(defun add (a b) (+ a b))
(defun subtract (a b) (- a b))

(defun factorial (n)
  (check-type n (integer 0))
  (if (<= n 1) 1 (* n (factorial (1- n)))))
