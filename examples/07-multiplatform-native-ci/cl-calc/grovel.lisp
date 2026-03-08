(in-package :cl-calc)

(include "calc.h")

(constant (+calc-max-value+ "CALC_MAX_VALUE") :type integer)

(cstruct calc-result "calc_result"
  (a "a" :type :int)
  (b "b" :type :int)
  (sum "sum" :type :int))
