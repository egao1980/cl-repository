(in-package :cl-calc)

(define-foreign-library libcalc
  (:darwin "libcalc.dylib")
  (:unix "libcalc.so")
  (t (:default "libcalc")))

(use-foreign-library libcalc)

(defcfun ("calc_add" %calc-add) (:struct calc-result)
  (a :int)
  (b :int))

(defcfun ("calc_version" calc-version) :string)

(defun calc-add (a b)
  "Add two integers via libcalc. Returns (values sum a b)."
  (let ((result (%calc-add a b)))
    (values (getf result 'sum)
            (getf result 'a)
            (getf result 'b))))
